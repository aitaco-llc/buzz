#!/usr/bin/env python3
"""Scripted stand-in for the Gemini Live API, for the voice-bridge lab only.

Session 1: greets on the bridge's first user turn; once it has heard about half
a second of the caller's tone, it transcribes a question and calls `work`,
saying "one sec" when the bridge's immediate tool response lands; when "Your
work came back" arrives it speaks the answer in the first person and sends
goAway. Session 2 must come back with session 1's resumption handle.
Every step is appended to $FAKE_GEMINI_LOG as JSON.
"""
import asyncio
import base64
import json
import math
import re
import os
import sys
import time

import websockets

LOG = open(os.environ["FAKE_GEMINI_LOG"], "a")
KEY = os.environ.get("FAKE_GEMINI_KEY", "lab-key")
sessions = 0


def log(**fields):
    LOG.write(json.dumps(fields) + "\n")
    LOG.flush()


def tone(seconds, hz, rate=24000):
    return b"".join(
        int(math.sin(2 * math.pi * hz * i / rate) * 6000).to_bytes(2, "little", signed=True)
        for i in range(int(seconds * rate))
    )


def speak(pcm, text):
    return [
        {"serverContent": {"modelTurn": {"parts": [{"inlineData": {
            "mimeType": "audio/pcm;rate=24000", "data": base64.b64encode(pcm).decode()}}]}}},
        {"serverContent": {"outputTranscription": {"text": text}, "turnComplete": True}},
    ]


async def handler(ws):
    global sessions
    sessions += 1
    me = sessions
    setup = json.loads(await ws.recv())["setup"]
    # websockets >= 13 exposes the handshake as `ws.request`; the legacy
    # server (12 and below, still what macOS's python3 ships) as
    # `ws.request_headers`.
    request = getattr(ws, "request", None)
    headers = request.headers if request is not None else ws.request_headers
    log(event="setup", session=me,
        key_ok=headers.get("x-goog-api-key") == KEY,
        model=setup["model"],
        tools=[f["name"] for t in setup["tools"] for f in t["functionDeclarations"]],
        handle=setup.get("sessionResumption", {}).get("handle"),
        transcription=("inputAudioTranscription" in setup and "outputAudioTranscription" in setup))
    await ws.send(json.dumps({"setupComplete": {}}))
    await ws.send(json.dumps({"sessionResumptionUpdate": {"newHandle": f"handle-{me}", "resumable": True}}))
    loud = 0
    asked = False
    # The working sound must never reach here. Measured over the span where
    # the caller is not talking: everything fed in then is the bridge's own,
    # and it is supposed to be silence. Counting from the ask instead would
    # count the caller's own voice, which is still arriving.
    last_loud = None
    peak_while_quiet = 0
    chunks_while_quiet = 0
    try:
        async for raw in ws:
            message = json.loads(raw)
            if "clientContent" in message:
                text = message["clientContent"]["turns"][0]["parts"][0]["text"]
                log(event="client_text", session=me, text=text)
                if "just joined" in text:
                    for m in speak(tone(0.6, 440), "Hi Lloyd, rock here."):
                        await ws.send(json.dumps(m))
                elif text.startswith("You are still working"):
                    # Speak back only what the bridge counted, as the persona
                    # requires; the scorer reads the number out of this.
                    seconds = re.search(r"been (\d+) seconds", text)
                    said = f"Still on it, it has been {seconds.group(1) if seconds else '?'} seconds."
                    for m in speak(tone(0.3, 300), said):
                        await ws.send(json.dumps(m))
                elif text.startswith("Your work came back"):
                    for m in speak(tone(0.8, 660), "The build is green."):
                        await ws.send(json.dumps(m))
                    await ws.send(json.dumps({"goAway": {"timeLeft": "1s"}}))
            elif "realtimeInput" in message:
                pcm = base64.b64decode(message["realtimeInput"]["audio"]["data"])
                peak = max((abs(int.from_bytes(pcm[i:i + 2], "little", signed=True))
                            for i in range(0, len(pcm), 2)), default=0)
                if peak > 1000:
                    loud += 1
                    last_loud = time.monotonic()
                elif asked and last_loud is not None and time.monotonic() - last_loud > 2:
                    chunks_while_quiet += 1
                    peak_while_quiet = max(peak_while_quiet, peak)
                if loud >= 25 and not asked and me == 1:
                    asked = True
                    log(event="heard_caller", session=me, loud_chunks=loud)
                    await ws.send(json.dumps({"serverContent": {"inputTranscription": {"text": "what is the build status"}}}))
                    await ws.send(json.dumps({"toolCall": {"functionCalls": [
                        {"id": "call-1", "name": "work", "args": {"request": "what is the build status"}}]}}))
            elif "toolResponse" in message:
                log(event="tool_response", session=me,
                    response=message["toolResponse"]["functionResponses"][0])
                for m in speak(tone(0.4, 520), "One sec, let me check."):
                    await ws.send(json.dumps(m))
    except websockets.ConnectionClosed:
        pass
    log(event="closed", session=me, loud_chunks=loud,
        peak_while_quiet=peak_while_quiet, chunks_while_quiet=chunks_while_quiet)


async def main():
    async with websockets.serve(handler, "127.0.0.1", int(sys.argv[1])):
        await asyncio.Future()


asyncio.run(main())

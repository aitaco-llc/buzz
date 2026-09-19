#!/usr/bin/env python3
"""A minimal ACP agent standing in for the rock seat in the voice-bridge lab.

Records every prompt it gets to $STUB_SEAT_LOG and answers each one by
replying in the triggering thread with `buzz messages send`, using the key
buzz-acp passes down. It replies ANSWER-$STUB_SEAT_NONCE.
"""
import json
import os
import re
import subprocess
import sys
import uuid

LOG = os.environ["STUB_SEAT_LOG"]
NONCE = os.environ["STUB_SEAT_NONCE"]


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    method, mid = message.get("method"), message.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1, "agentCapabilities": {"loadSession": False},
            "agentInfo": {"name": "stub-seat", "version": "0"}}})
    elif method == "session/new":
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": str(uuid.uuid4())}})
    elif method == "session/prompt":
        text = json.dumps(message["params"]["prompt"])
        event = re.search(r"Event ID: ([0-9a-f]{64})", text)
        channel = re.search(r"Channel: [^\\\n]*?\(#?([0-9a-f-]{36})\)", text)
        with open(LOG, "a") as out:
            out.write(json.dumps({"event": event and event.group(1),
                                  "channel": channel and channel.group(1),
                                  "voice_bridge_ask": "voice-bridge" in text}) + "\n")
        if event and channel:
            subprocess.run(["buzz", "--format", "compact", "messages", "send",
                            "--channel", channel.group(1), "--reply-to", event.group(1),
                            "--content", f"ANSWER-{NONCE}: the build is green"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})

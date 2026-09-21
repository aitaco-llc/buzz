#!/usr/bin/env python3
"""A minimal ACP agent standing in for the rock seat in the voice-bridge lab.

Records every prompt it gets to $STUB_SEAT_LOG and answers each one by
replying in the triggering thread with `buzz messages send`, using the key
buzz-acp passes down. It replies ANSWER-$STUB_SEAT_NONCE.

$STUB_SEAT_DELAY_SECS holds the answer back, so the lab can exercise what the
caller hears while the seat is thinking: the progress line and the working
sound. Zero, the default, answers as fast as the seat can.

$STUB_SEAT_RATE_LIMIT makes it refuse the way a provider usage limit does,
instead of answering: a `usage_update` notification carrying the SDK's
`_claude/rateLimit` report, then a -32603 whose `data` names the kind. Both
signals, in the order and shape claude-agent-acp 0.79.0 sends them
(`acp-agent.js:4359` forwards `rate_limit_info` untouched). Its value is the
unix instant the window resets, so a lab run can choose a deadline it will
live to see.
"""
import json
import os
import re
import subprocess
import sys
import time
import uuid

LOG = os.environ["STUB_SEAT_LOG"]
NONCE = os.environ["STUB_SEAT_NONCE"]
DELAY = float(os.environ.get("STUB_SEAT_DELAY_SECS", "0"))
# Unix seconds for the refusal's resetsAt; empty or unset means answer normally.
RATE_LIMIT = os.environ.get("STUB_SEAT_RATE_LIMIT", "").strip()


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
        if RATE_LIMIT:
            # The report rides a notification, in a different message from the
            # error — which is the whole reason buzz-acp has to collect it
            # separately from the failure.
            send({"jsonrpc": "2.0", "method": "session/update", "params": {
                "sessionId": message["params"].get("sessionId"),
                "update": {
                    "sessionUpdate": "usage_update",
                    "used": 1000,
                    "size": 200000,
                    "_meta": {"_claude/rateLimit": {
                        "status": "rejected",
                        "rateLimitType": "five_hour",
                        "resetsAt": int(RATE_LIMIT),
                        "overageStatus": "rejected",
                    }},
                }}})
            send({"jsonrpc": "2.0", "id": mid, "error": {
                "code": -32603,
                "message": "Internal error: You've hit your session limit \u00b7 resets 1:10am (America/Denver)",
                "data": {"errorKind": "rate_limit"},
            }})
            continue
        if event and channel:
            time.sleep(DELAY)
            subprocess.run(["buzz", "--format", "compact", "messages", "send",
                            "--channel", channel.group(1), "--reply-to", event.group(1),
                            "--content", f"ANSWER-{NONCE}: the build is green"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})

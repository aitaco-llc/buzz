#!/usr/bin/env python3
"""A GPU-free stand-in for `rebrand serve`, for proving the Buzz side.

It speaks the same `/v1/chat/completions` contract as Rebrand's single-model
server and is as strict about the request: an unknown top-level field is a
400, as with Rebrand's `deny_unknown_fields`. Instead of a model it plays one
scripted turn:

1. First call: a tool call to the MCP shell tool that posts the requested
   reply with `buzz messages send`, using the channel and the `--reply-to`
   anchor the harness put in the prompt.
2. After the tool result: a short final message, `finish_reason: stop`.

If the prompt lacks the channel, the anchor, or the requested reply text, it
answers in plain text instead, so the proof fails visibly rather than
guessing.
"""

import argparse
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from rebrand_schema import unknown_fields

CHANNEL_RE = re.compile(r"\(#([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\)")
ANCHOR_RE = re.compile(r"--reply-to ([0-9a-f]{64})")
REPLY_RE = re.compile(r"exactly: (PONG-[A-Za-z0-9]+)")


def text_of(message):
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(p.get("text", "") for p in content if isinstance(p, dict))
    return ""


def completion(message, finish_reason, prompt_chars):
    return {
        "id": f"chatcmpl-stub-{int(time.time() * 1000)}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": "stub",
        "choices": [{"index": 0, "message": message, "finish_reason": finish_reason}],
        "usage": {
            "prompt_tokens": prompt_chars // 4,
            "completion_tokens": 16,
            "total_tokens": prompt_chars // 4 + 16,
        },
    }


def respond(body):
    messages = body.get("messages") or []
    all_text = "\n".join(text_of(m) for m in messages)
    prompt_chars = len(all_text)

    if any(m.get("role") == "tool" for m in messages):
        return completion({"role": "assistant", "content": "Replied in the thread."}, "stop", prompt_chars)

    tools = body.get("tools") or []
    shell = next(
        (t["function"]["name"] for t in tools if t.get("function", {}).get("name", "").endswith("shell")),
        None,
    )
    channel = CHANNEL_RE.search(all_text)
    anchor = ANCHOR_RE.search(all_text)
    reply = REPLY_RE.search(all_text)
    missing = [
        name
        for name, found in (("shell tool", shell), ("channel", channel), ("reply anchor", anchor), ("reply text", reply))
        if not found
    ]
    if missing:
        return completion(
            {"role": "assistant", "content": "stub cannot act; prompt is missing: " + ", ".join(missing)},
            "stop",
            prompt_chars,
        )

    command = (
        f"buzz messages send --channel {channel.group(1)} "
        f"--reply-to {anchor.group(1)} --content {reply.group(1)}"
    )
    call = {
        "id": f"call_stub_{int(time.time() * 1000)}",
        "type": "function",
        "function": {"name": shell, "arguments": json.dumps({"command": command})},
    }
    return completion({"role": "assistant", "content": None, "tool_calls": [call]}, "tool_calls", prompt_chars)


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/health", "/v1/health"):
            self._send(200, {"status": "ok"})
        elif self.path == "/v1/models":
            self._send(200, {"object": "list", "data": [{"id": "stub", "object": "model"}]})
        else:
            self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self._send(404, {"error": {"message": "not found"}})
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError as error:
            self._send(400, {"error": {"message": f"invalid JSON: {error}"}})
            return
        unknown = unknown_fields(body)
        if unknown:
            # Same failure a real Rebrand server gives (deny_unknown_fields).
            self._send(400, {"error": {"message": f"unknown field `{unknown[0]}`"}})
            return
        if body.get("stream"):
            self._send(400, {"error": {"message": "stub does not stream"}})
            return
        self._send(200, respond(body))

    def log_message(self, fmt, *args):
        sys.stderr.write("stub_llm: " + fmt % args + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8099)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

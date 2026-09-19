#!/usr/bin/env python3
"""A recording proxy between buzz-agent and an OpenAI-compatible backend.

Every request is forwarded unchanged. One JSON line per call is appended to
`--log`, so the same numbers come out of the stub, Ollama and `rebrand serve`:

  latency_s, status, request_bytes, messages, tools, prompt_chars,
  unknown_fields (top-level fields Rebrand would reject), finish_reason,
  tool_calls, content_chars, reasoning_chars, usage, error.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from rebrand_schema import unknown_fields

BACKEND = ""
LOG_PATH = ""
TIMEOUT_S = 900


def prompt_chars(messages):
    total = 0
    for message in messages or []:
        content = message.get("content")
        if isinstance(content, str):
            total += len(content)
        elif isinstance(content, list):
            total += sum(len(p.get("text", "")) for p in content if isinstance(p, dict))
    return total


def record(entry):
    with open(LOG_PATH, "a", encoding="utf-8") as log:
        log.write(json.dumps(entry) + "\n")


class Handler(BaseHTTPRequestHandler):
    def _forward(self, method, body):
        request = urllib.request.Request(
            BACKEND + self.path,
            data=body,
            method=method,
            headers={"Content-Type": self.headers.get("Content-Type", "application/json")},
        )
        started = time.monotonic()
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
                status, data = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, data = error.code, error.read()
        except Exception as error:  # connection refused, timeout
            status, data = 502, json.dumps({"error": {"message": f"proxy: {error}"}}).encode()
        return status, data, time.monotonic() - started

    def _reply(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        status, data, _ = self._forward("GET", None)
        self._reply(status, data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        status, data, latency = self._forward("POST", body)
        self._reply(status, data)

        entry = {"ts": time.time(), "path": self.path, "status": status, "latency_s": round(latency, 3),
                 "request_bytes": len(body)}
        try:
            request = json.loads(body or b"{}")
            entry.update(
                messages=len(request.get("messages") or []),
                tools=len(request.get("tools") or []),
                prompt_chars=prompt_chars(request.get("messages")),
                unknown_fields=unknown_fields(request),
                max_completion_tokens=request.get("max_completion_tokens"),
            )
        except json.JSONDecodeError:
            entry["request_error"] = "request is not JSON"
        try:
            response = json.loads(data or b"{}")
            choice = (response.get("choices") or [{}])[0]
            message = choice.get("message") or {}
            entry.update(
                finish_reason=choice.get("finish_reason"),
                tool_calls=len(message.get("tool_calls") or []),
                content_chars=len(message.get("content") or ""),
                # Rebrand says `reasoning_content`; Ollama's OpenAI shim says `reasoning`.
                reasoning_chars=len(message.get("reasoning_content") or message.get("reasoning") or ""),
                usage=response.get("usage"),
            )
            if status != 200:
                entry["error"] = json.dumps(response.get("error", response))[:500]
        except json.JSONDecodeError:
            entry["error"] = data[:500].decode("utf-8", "replace")
        record(entry)

    def log_message(self, fmt, *args):
        sys.stderr.write("llm_proxy: " + fmt % args + "\n")


def main():
    global BACKEND, LOG_PATH, TIMEOUT_S
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", type=int, default=8098)
    parser.add_argument("--backend", required=True, help="e.g. http://127.0.0.1:8000 (no /v1)")
    parser.add_argument("--log", required=True)
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    BACKEND, LOG_PATH, TIMEOUT_S = args.backend.rstrip("/"), args.log, args.timeout
    ThreadingHTTPServer(("127.0.0.1", args.listen), Handler).serve_forever()


if __name__ == "__main__":
    main()

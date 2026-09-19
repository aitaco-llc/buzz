#!/usr/bin/env python3
"""Minimal check of `rebrand serve`'s schema-constrained answer, with and without thinking.

Found while running the proof through rebrand-acp on 2026-09-19 (Rebrand 31fc194,
qwen3-8b-q4_k_m): with thinking on, a schema whose object holds an array of strings,
and greedy sampling, the last string in the array never closes. The model writes
`'` where `"` belongs, so `']}` becomes string content and the document runs on.
The same request with `reasoning_effort: "none"`, or with no array in the schema,
is correct JSON.

    REBRAND_BIN=... REBRAND_MODEL=... python3 grammar_repro.py

Starts and stops one `rebrand serve` of its own; nothing else may hold the card.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

BIN = os.environ.get("REBRAND_BIN", "rebrand")
MODEL = os.environ["REBRAND_MODEL"]
PORT = int(os.environ.get("REBRAND_PORT", "18078"))
SEQ = os.environ.get("REBRAND_MAX_SEQ_LEN", "32768")

ARRAY = {
    "type": "object",
    "properties": {
        "answer": {"type": "string", "minLength": 1},
        "source_ids": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 5},
    },
    "required": ["answer", "source_ids"],
    "additionalProperties": False,
}
PLAIN = {"type": "object", "properties": {"answer": {"type": "string"}},
         "required": ["answer"], "additionalProperties": False}
ASK = [{"role": "system", "content": "Answer with JSON: answer (string) and source_ids (array of strings)."},
       {"role": "user", "content": "Say ok, citing source A1."}]

CASES = {
    # The failure, at its smallest.
    "array + thinking on, greedy": dict(messages=ASK, response_format={"type": "json_schema", "json_schema": {"name": "a", "schema": ARRAY}}),
    # The same request with thinking off.
    "array + thinking off, greedy": dict(messages=ASK, reasoning_effort="none", response_format={"type": "json_schema", "json_schema": {"name": "a", "schema": ARRAY}}),
    # The same thinking, no array in the schema.
    "no array + thinking on, greedy": dict(messages=ASK, response_format={"type": "json_schema", "json_schema": {"name": "a", "schema": PLAIN}}),
    # The same thinking, the schema described but not enforced.
    "array schema not enforced": dict(messages=ASK),
}
# A constrained answer that is not JSON is the constraint failing. The
# unconstrained case is context, and may be prose.
CONSTRAINED = [name for name in CASES if "not enforced" not in name]


def post(body):
    request = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/v1/chat/completions",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=300))


def main():
    serve = subprocess.Popen(
        [BIN, "serve", "--model", MODEL, "--host", "127.0.0.1", "--port", str(PORT), "--max-seq-len", SEQ],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(600):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{PORT}/health", timeout=2)
                break
            except Exception:
                time.sleep(1)
        bad = 0
        for name, extra in CASES.items():
            reply = post(dict(model="qwen3", temperature=0.0, max_tokens=2048, stream=False, **extra))
            choice = reply["choices"][0]
            text = choice["message"]["content"]
            try:
                json.loads(text)
                verdict = "JSON"
            except ValueError:
                verdict = "NOT JSON"
            if verdict == "NOT JSON" and name in CONSTRAINED:
                bad += 1
            print(f"=== {name}: {verdict}, finish_reason={choice['finish_reason']}\n{text[:400]}\n")
        return 1 if bad else 0
    finally:
        serve.terminate()
        serve.wait(timeout=60)


if __name__ == "__main__":
    sys.exit(main())

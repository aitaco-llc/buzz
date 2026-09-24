#!/usr/bin/env python3
"""Minimal check of `rebrand serve`'s schema-constrained answer, with and without thinking.

Found while running the proof through rebrand-acp on 2026-09-19 (Rebrand 31fc194,
qwen3-8b-q4_k_m): with thinking on and a schema whose object holds an array of
strings, the last string in the array often never closes. The model writes `'`
where `"` belongs, so `']}` becomes string content and the grammar keeps the
document open, padding the array until something can close it.

The wreckage is still schema-valid JSON, so `json.loads` succeeding proves
nothing: it is how this failure reached a caller as `end_turn`. A case passes
here only when the citation round-trips — `source_ids == ["A1"]`, one of each
key, and nothing after the closing brace.

Greedy sampling makes it near-certain but is not necessary: in the proof loop it
fired 9 of 11 runs at temperature 0.0 and 2 of 10 at 0.7. One request at 0.7 is
one draw of a sampled setting, so every case runs REBRAND_REPEATS times and
reports a rate.

neil diagnosed it in aitaco-llc/rebrand#300 (`a8a0500`), and the condition is
narrower than these cases: `ArrayScope::items()` credited an element only once it
reached a structural position of its array, so an array being written at its
**first** element read as holding nothing. The `minItems` deficit that followed
denied exactly the tokens that close the string and the array together (`"]`,
`"]}`), while the apostrophe twins (`']`, `']}`) stayed allowed because they never
leave the string. Greedy then takes the best survivor. The mask is a function of
the automaton state alone, so thinking is not a condition either: with thinking
off this model writes the array pretty-printed and closes each level with its own
token, none of which was denied. The same undercount let a one-item array take a
second element past `maxItems: 1`.

So a row that passes below is not a safe configuration; it is a model that did not
happen to need a denied token. The row that matters is the first.

    REBRAND_BIN=... REBRAND_MODEL=... [REBRAND_REPEATS=3] python3 grammar_repro.py

Starts and stops one `rebrand serve` of its own; nothing else may hold the card.
Offline, `--check FILE [expected_id ...]` re-reads a saved capture
({case: {"text": ...}}) through the same verdict, with no GPU and no server.
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

BIN = os.environ.get("REBRAND_BIN", "rebrand")
MODEL = os.environ.get("REBRAND_MODEL")  # required for a live run, not for --check
PORT = int(os.environ.get("REBRAND_PORT", "18078"))
SEQ = os.environ.get("REBRAND_MAX_SEQ_LEN", "32768")
REPEATS = int(os.environ.get("REBRAND_REPEATS", "1"))

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

ARRAY_FORMAT = {"type": "json_schema", "json_schema": {"name": "a", "schema": ARRAY}}
CITED = ["A1"]  # the only source the prompt offers, so the correct source_ids
STRAY = re.compile(r"""[\s{}\[\]"']""")  # what a citation never holds

CASES = {
    # The failure, at its smallest.
    "array + thinking on, greedy": dict(messages=ASK, response_format=ARRAY_FORMAT),
    # The same request, sampled. Fires less often, not never.
    "array + thinking on, temperature 0.7": dict(messages=ASK, temperature=0.7, response_format=ARRAY_FORMAT),
    # The same request with thinking off.
    "array + thinking off, greedy": dict(messages=ASK, reasoning_effort="none", response_format=ARRAY_FORMAT),
    # The same thinking, no array in the schema.
    "no array + thinking on, greedy": dict(messages=ASK, response_format={"type": "json_schema", "json_schema": {"name": "a", "schema": PLAIN}}),
    # The same thinking, the schema described but not enforced.
    "array schema not enforced": dict(messages=ASK),
}
# A constrained answer the citation does not survive is the constraint failing.
# The unconstrained case is context, and may be prose.
CONSTRAINED = [name for name in CASES if "not enforced" not in name]


def verdict(text, want_array, expected=None):
    """Why this answer is or isn't the one the schema asked for.

    `json.loads` succeeding is not the test: the failure's wreckage parses. The
    citation has to come back the way it went in.
    """
    seen = []
    try:
        parsed = json.loads(text, object_pairs_hook=lambda pairs: (seen.extend(k for k, _ in pairs), dict(pairs))[1])
    except ValueError as invalid:
        return False, f"not JSON ({invalid})"
    if len(seen) != len(set(seen)):
        return False, f"keys repeated: {sorted(k for k in set(seen) if seen.count(k) > 1)}"
    if not isinstance(parsed.get("answer"), str) or not parsed["answer"]:
        return False, "no answer string"
    if not want_array:
        return True, "clean"
    ids = parsed.get("source_ids")
    if not isinstance(ids, list):
        return False, f"source_ids {ids!r} is not a list"
    # The fault's own signature, and it needs no knowledge of the prompt: the
    # grammar closes the unterminated string by swallowing punctuation and
    # newlines into the citation, so an element stops looking like an id.
    for one in ids:
        if not isinstance(one, str) or not one or STRAY.search(one):
            return False, f"citation is not an identifier: {one!r}"
    if expected is None:
        # A capture from another prompt: the ids are id-shaped, and only the
        # asker knows whether they are the right ones.
        return True, f"parses, source_ids {ids!r} unchecked"
    if ids != expected:
        return False, f"source_ids {ids!r}, not {expected!r}"
    return True, "clean"


def post(body):
    request = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/v1/chat/completions",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(request, timeout=300))


def check_capture(path, expected=None):
    """Run the verdict over a saved capture, so the detector is testable offline.

    Without `expected`, a capture made by another prompt is judged only on the
    faults that hold whatever it asked: it has to parse, carry each key once,
    and hold an answer.
    """
    bad = 0
    for name, case in json.load(open(path)).items():
        text = case["text"] if isinstance(case, dict) else case
        want_array = "no array" not in name and "simple" not in name
        ok, why = verdict(text, want_array, expected)
        print(f"=== {name}: {'clean' if ok else 'CORRUPT'} — {why}")
        if not ok:
            bad += 1
    return 1 if bad else 0


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--check":
        return check_capture(sys.argv[2], sys.argv[3:] or None)
    if not MODEL:
        sys.exit("REBRAND_MODEL is required for a live run")
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
        rates = {}
        for name, extra in CASES.items():
            want_array = "no array" not in name
            corrupt = 0
            for attempt in range(REPEATS):
                body = dict(model="qwen3", temperature=0.0, max_tokens=2048, stream=False)
                body.update(extra)
                reply = post(body)
                choice = reply["choices"][0]
                text = choice["message"]["content"]
                ok, why = verdict(text, want_array, CITED)
                if not ok:
                    corrupt += 1
                print(f"=== {name} [{attempt + 1}/{REPEATS}]: {'clean' if ok else 'CORRUPT'} — {why}, "
                      f"finish_reason={choice['finish_reason']}\n{text[:400]}\n")
            rates[name] = corrupt
        print("corrupt / runs:")
        for name, corrupt in rates.items():
            print(f"  {corrupt}/{REPEATS}  {name}")
        return 1 if any(rates[name] for name in CONSTRAINED) else 0
    finally:
        serve.terminate()
        serve.wait(timeout=60)


if __name__ == "__main__":
    sys.exit(main())

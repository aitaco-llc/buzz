#!/usr/bin/env python3
"""Score a task extractor against the labelled corpus.

The extractor turns one of Lloyd's messages into zero or more tasks. This
scores that decision against hand-assigned labels, and applies the one gate
`PLANS/BUZZ_TASK_TRACKER_ARCHITECTURE_2026-09-23.md` §11 sets, widened by
one finding: **no work the audit recorded may go unextracted** — neither as a
false `none`, nor as a `create` that returns fewer tasks than the message
asked for. A missed task is the failure mode the whole tracker exists to
remove; a spurious one is visible on the board and can be closed. That
asymmetry is why an undercount fails the gate and an overcount does not.

It scores PREDICTIONS, not a model, so the same scorer grades a stub, a live
extractor or a replay of a saved run — and so it can be exercised with no
relay, no GPU and no key.

    # the control: an extractor that says `none` to everything. MUST fail.
    ./task-extractor-eval.py --stub none

    # score a real run
    ./task-extractor-eval.py --predictions run.json

    # resolve each utterance's text from the relay, to feed an extractor
    ./task-extractor-eval.py --fetch > utterances.json

Predictions file: `{"<8-hex utterance id>": {"action": "...", "count": N}}`.
`count` is required for `create` and ignored otherwise.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CORPUS = HERE / "corpus.json"
ACTIONS = ("create", "attach", "none")

# Channel UUIDs, so --fetch can resolve an id without a directory lookup. An
# utterance in a channel absent from here cannot be fetched from this seat,
# which is the point of the `coverage` line in the corpus.
CHANNELS = {
    "general": "72fa2e7b-7e86-437c-a9ca-872838e64dbb",
    "buzz-platform": "8dd69e3d-8b3c-49fd-ad42-a3e32f495379",
    "ml-platform": "bf0d3b7a-a38a-4b87-8c7d-d306db74eab5",
    "game-dev": "86626078-e765-496b-8d38-aabffbb27974",
    "game-platform": "977cc4fa-d527-4b42-99bd-1f1fe47ea1e9",
    "studio": "ebeaf7af-dfbc-4a39-8873-f0d64519e730",
    "fleet-health": "f71dbb47-ff3f-4642-b623-7f48ab369ae5",
}


def load_corpus(path: Path) -> dict:
    corpus = json.loads(path.read_text())
    seen = set()
    for u in corpus["utterances"]:
        if u["expect"]["action"] not in ACTIONS:
            sys.exit(f"corpus: {u['id']} has unknown action {u['expect']['action']!r}")
        if u["id"] in seen:
            sys.exit(f"corpus: {u['id']} appears twice")
        seen.add(u["id"])
        # A `create` with no count cannot be scored on 2.1, which is the
        # finding this corpus exists to carry. Refuse it rather than default it.
        if u["expect"]["action"] == "create" and u["expect"].get("count", 0) < 1:
            sys.exit(f"corpus: {u['id']} is a create with no task count")
    return corpus


def fetch_text(corpus: dict) -> list[dict]:
    """Resolve each utterance from the relay. The corpus stores no message text."""
    window = corpus["window"]
    by_channel: dict[str, list[dict]] = {}
    out = []
    for u in corpus["utterances"]:
        channel = u["channel"]
        uuid = CHANNELS.get(channel)
        if uuid is None:
            out.append({**u, "text": None, "error": f"no channel uuid for {channel}"})
            continue
        if channel not in by_channel:
            raw = subprocess.run(
                ["buzz", "messages", "get", "--channel", uuid,
                 "--since", str(window["from"]), "--limit", "500"],
                capture_output=True, text=True, check=False,
            )
            if raw.returncode != 0:
                out.append({**u, "text": None, "error": raw.stderr.strip()[:200]})
                continue
            by_channel[channel] = json.loads(raw.stdout)
        hit = next(
            (m for m in by_channel[channel] if m.get("id", "").startswith(u["id"])),
            None,
        )
        if hit is None:
            out.append({**u, "text": None, "error": "not returned by the relay"})
        else:
            out.append({**u, "text": hit["content"], "eventId": hit["id"]})
    return out


def score(corpus: dict, predictions: dict) -> dict:
    confusion: dict[tuple[str, str], int] = {}
    rows, missing, count_errors, false_none = [], [], [], []
    for u in corpus["utterances"]:
        want = u["expect"]
        got = predictions.get(u["id"])
        if got is None:
            missing.append(u["id"])
            continue
        got_action = got.get("action")
        confusion[(want["action"], got_action)] = (
            confusion.get((want["action"], got_action), 0) + 1
        )
        ok = got_action == want["action"]
        count_ok = True
        if want["action"] == "create" and got_action == "create":
            # 2.1: an extractor that calls a four-ask message a create and
            # returns one task has the label right and the work wrong.
            count_ok = got.get("count") == want["count"]
            if not count_ok:
                count_errors.append(
                    {"id": u["id"], "want": want["count"], "got": got.get("count")}
                )
        # The gate. Only for rows the audit recorded, and only for work that
        # went MISSING — a task too few, never a task too many. The asymmetry
        # is the whole rationale: a spurious task sits on the board where
        # someone closes it, a missing one is the failure this project exists
        # to remove. So an undercount counts, and an overcount does not.
        if u.get("audit"):
            if want["action"] != "none" and got_action == "none":
                false_none.append({"id": u["id"], "why": "extracted as `none`",
                                   "audit": u["audit"]})
            elif (want["action"] == "create" and got_action == "create"
                  and (got.get("count") or 0) < want["count"]):
                false_none.append({
                    "id": u["id"],
                    "why": f"{want['count']} tasks asked for, {got.get('count')} extracted",
                    "audit": u["audit"]})
        rows.append({"id": u["id"], "want": want["action"], "got": got_action,
                     "ok": ok and count_ok})
    return {
        "rows": rows,
        "confusion": confusion,
        "missing": missing,
        "countErrors": count_errors,
        "falseNone": false_none,
        "scored": len(rows),
        "correct": sum(1 for r in rows if r["ok"]),
    }


def report(corpus: dict, result: dict) -> int:
    print(f"corpus: {CORPUS}  ({len(corpus['utterances'])} utterances)")
    print(f"window: {corpus['window']['utc']}")
    print(f"coverage: {corpus['coverage']}\n")
    for r in result["rows"]:
        mark = "PASS" if r["ok"] else "FAIL"
        print(f"  {mark}  {r['id']}  want={r['want']:<7} got={r['got']}")
    if result["missing"]:
        print(f"\n  NO PREDICTION for {len(result['missing'])}: "
              f"{', '.join(result['missing'])}")
    print(f"\naction confusion (want -> got):")
    for want in ACTIONS:
        line = "  ".join(
            f"{got}={result['confusion'].get((want, got), 0)}" for got in ACTIONS
        )
        print(f"  {want:<7} {line}")
    if result["countErrors"]:
        print("\ntask-count errors on `create` rows:")
        for e in result["countErrors"]:
            print(f"  {e['id']}  want {e['want']} tasks, got {e['got']}")
    print(f"\nscored {result['scored']}, correct {result['correct']}")

    # The gate. Not a score threshold: one specific class of miss.
    if result["missing"]:
        print("\nGATE FAILED: an utterance got no prediction at all.")
        return 1
    if result["falseNone"]:
        print("\nGATE FAILED: work the audit recorded was not extracted.")
        for e in result["falseNone"]:
            print(f"  {e['id']} — {e['why']}")
            print(f"      {e['audit']}")
        return 1
    print("\nGATE PASSED: every task the audit recorded was extracted.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", type=Path, default=CORPUS)
    ap.add_argument("--predictions", type=Path,
                    help="JSON: {utterance-id: {action, count}}")
    ap.add_argument("--stub", choices=ACTIONS,
                    help="answer this for every utterance; `none` is the control run")
    ap.add_argument("--fetch", action="store_true",
                    help="resolve each utterance's text from the relay and print it")
    args = ap.parse_args()

    corpus = load_corpus(args.corpus)

    if args.fetch:
        print(json.dumps(fetch_text(corpus), indent=1, ensure_ascii=False))
        return 0
    if args.stub:
        predictions = {
            u["id"]: {"action": args.stub, "count": 1 if args.stub == "create" else 0}
            for u in corpus["utterances"]
        }
    elif args.predictions:
        predictions = json.loads(args.predictions.read_text())
    else:
        ap.error("one of --predictions, --stub or --fetch is required")

    return report(corpus, score(corpus, predictions))


if __name__ == "__main__":
    sys.exit(main())

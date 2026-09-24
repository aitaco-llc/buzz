#!/usr/bin/env python3
"""Assert the Voice Bridge workflow's two `paths:` filters are identical.

GitHub Actions does not expand YAML anchors, so `push` and `pull_request` each
carry their own copy of the list. Drift between them is silent in the worst
direction: the PR still runs the gate, main stops being gated, and nothing
anywhere says so. This is the check that notices.

Run with no argument to check the workflow in this checkout, or pass a path.
"""

from __future__ import annotations

import sys
from pathlib import Path

DEFAULT = Path(__file__).resolve().parents[3] / ".github/workflows/voice-bridge.yml"


def filters(text: str) -> dict[str, list[str]]:
    """The `paths:` list under each top-level `on:` event, in file order."""
    found: dict[str, list[str]] = {}
    event: str | None = None
    collecting = False
    for raw in text.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if collecting:
            if indent >= 6 and stripped.startswith("- "):
                found[event].append(stripped[2:].strip().strip("'\""))
                continue
            collecting = False
        if indent == 2 and stripped.endswith(":"):
            event = stripped[:-1]
        elif indent == 4 and stripped == "paths:" and event is not None:
            found[event] = []
            collecting = True
    return found


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    found = filters(path.read_text())
    missing = [event for event in ("push", "pull_request") if event not in found]
    if missing:
        print(f"{path}: no paths: filter under {', '.join(missing)}", file=sys.stderr)
        return 1
    push, pull = found["push"], found["pull_request"]
    if push != pull:
        print(f"{path}: push and pull_request paths: filters differ", file=sys.stderr)
        for entry in sorted(set(push) - set(pull)):
            print(f"  push only:         {entry}", file=sys.stderr)
        for entry in sorted(set(pull) - set(push)):
            print(f"  pull_request only: {entry}", file=sys.stderr)
        if sorted(push) == sorted(pull):
            print("  same entries, different order", file=sys.stderr)
        return 1
    print(f"{path}: push and pull_request agree on {len(push)} paths")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

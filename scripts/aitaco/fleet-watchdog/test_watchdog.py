#!/usr/bin/env python3
"""Regression tests for the fleet watchdog, run against saved sheets.

These are not synthetic. Both fixtures were captured from hip's real turn logs
with `watchdog.py --capture`:

  * `sheet-2026-09-22T0052Z-limit-outage.json` is the instant two minutes after
    the five-hour usage window reset on 2026-09-22, reconstructed with `--at`.
    67 triggers across four seats had been refused. The first draft of the
    detector found NOTHING in it — turn files are named by UUID so sorting them
    by name is not sorting them by time, and the rate-limit report sits a few
    records before the end of a failed turn rather than on its last line. Both
    bugs are what this fixture exists to keep out.
  * `sheet-live-clean.json` is a healthy fleet. It is the other half of the
    pair: a detector that fires on everything is as useless as one that fires
    on nothing, and only the clean sheet can catch that.

Run: python3 test_watchdog.py
"""

import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import watchdog  # noqa: E402

HERE = Path(__file__).parent
OUTAGE = HERE / "fixtures" / "sheet-2026-09-22T0052Z-limit-outage.json"
# The same outage twenty-two minutes earlier, while the provider was still
# refusing. The distinction is the whole point of the restart veto: at 00:52Z
# the window had reset and a restart was safe again, so the veto must be off.
IN_FORCE = HERE / "fixtures" / "sheet-2026-09-22T0030Z-limit-in-force.json"
CLEAN = HERE / "fixtures" / "sheet-live-clean.json"
# A healthy fleet WITH the relay layer, captured live and then sanitised: every
# message keeps its id, pubkey, timestamp and tags, and its prose is reduced to
# the @-tokens the dropped-trigger detector actually reads.
RELAY = HERE / "fixtures" / "sheet-live-relay.json"

failures: list[str] = []
skipped: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def skip(name: str, why: str) -> None:
    """Announce a skip loudly and count it.

    A test that silently skips when its inputs are absent reads exactly like a
    test that passed, which is how a green sheet comes to mean nothing.
    """
    print(f"SKIP  {name} — {why}")
    skipped.append(name)


def judge(path: Path) -> list[dict]:
    sheet = json.loads(path.read_text())
    return watchdog.evaluate(sheet, {"keys": {}, "restarts": {}}, watchdog.roster())


def check_ordering() -> None:
    """Two turn files whose UUID order is the reverse of their mtime order.

    `zzz...` sorts last by name but is written first and back-dated; `aaa...`
    sorts first by name and is the newer file. A collector that trusts the name
    reads the stale `allowed` report and concludes the fleet is fine while the
    provider is refusing it.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "seat" / "turns" / "2026-09-22"
        root.mkdir(parents=True)
        # seats_on_disk() identifies a seat by its index/ directory, so a seat
        # without one is invisible — which is itself worth knowing: a turn
        # directory alone is not a seat.
        (Path(tmp) / "seat" / "index").mkdir(parents=True)

        def write(name: str, ts: str, status: str, resets: int, mtime: float) -> None:
            rec = {
                "kind": "acp_read",
                "timestamp": ts,
                "payload": {
                    "params": {
                        "update": {
                            "sessionUpdate": "usage_update",
                            "_meta": {
                                "_claude/rateLimit": {
                                    "status": status,
                                    "rateLimitType": "five_hour",
                                    "resetsAt": resets,
                                }
                            },
                        }
                    }
                },
            }
            path = root / name
            path.write_text(json.dumps(rec) + "\n")
            os.utime(path, (mtime, mtime))

        newest = watchdog.parse_ts("2026-09-22T00:40:00Z")
        older = watchdog.parse_ts("2026-09-21T20:00:00Z")
        # name-last, time-oldest, and quiet
        write("zzzzzzzz.jsonl", "2026-09-21T20:00:00+00:00", "allowed", 1, older)
        # name-first, time-newest, and refusing
        write("aaaaaaaa.jsonl", "2026-09-22T00:40:00+00:00", "rejected", 1790038200, newest)

        prev_root = watchdog.TURN_ROOT
        watchdog.TURN_ROOT = Path(tmp)
        try:
            got = watchdog.latest_limit_report(watchdog.parse_ts("2026-09-22T00:52:00Z"))
        finally:
            watchdog.TURN_ROOT = prev_root

    check(
        "ordering: the newest file wins even when its name sorts first",
        got is not None and got["report"].get("status") == "rejected",
        f"picked {got['report'].get('status') if got else None} "
        f"({watchdog.iso(got['ts']) if got else None})",
    )


def main() -> int:
    outage = judge(OUTAGE)
    clean = judge(CLEAN)
    by_class = lambda fs, c: [f for f in fs if f["class"] == c]  # noqa: E731

    # --- the outage sheet must be seen as an outage -------------------------
    limits = by_class(outage, "LIMIT")
    check("outage: LIMIT is raised", len(limits) == 1, f"got {len(limits)}")
    if limits:
        ev = limits[0]["evidence"]
        check(
            "outage: the window is identified as five_hour",
            ev.get("window") == "five_hour",
            str(ev.get("window")),
        )
        check(
            "outage: resetsAt is the real one (2026-09-22T00:50:00Z)",
            ev.get("resetsAtIso") == "2026-09-22T00:50:00Z",
            str(ev.get("resetsAtIso")),
        )
        refused = ev.get("held", []) + ev.get("killed", []) + ev.get("unknown", [])
        check(
            "outage: all four refused seats are named",
            {r["seat"] for r in refused} == {"aldrin", "matt", "rock", "vinge"},
            str(sorted(r["seat"] for r in refused)),
        )
        check(
            "outage: the refused-turn count is the real 67",
            sum(r["turns"] for r in refused) == 67,
            str(sum(r["turns"] for r in refused)),
        )
        check(
            "outage: an unprobed harness is reported as unknown, never as discarded",
            not ev.get("killed") and len(ev.get("unknown", [])) == 4,
            f"killed={ev.get('killed')} unknown={len(ev.get('unknown', []))}",
        )

    orphans = by_class(outage, "ORPHAN")
    check(
        "outage: the four reboot orphans are raised",
        len(orphans) == 4,
        f"got {len(orphans)}",
    )
    check(
        "outage: every orphan names its seat and turn",
        all(o["evidence"].get("seat") and o["evidence"].get("turnId") for o in orphans),
    )

    # --- the clean sheet must be seen as clean ------------------------------
    check("clean: nothing is raised", clean == [], f"got {[f['class'] for f in clean]}")

    # --- the detector must be a function of the sheet alone -----------------
    # If this fails, `--check` is not a replay and the fixtures prove nothing.
    check(
        "evaluate() is deterministic",
        [f["key"] for f in judge(OUTAGE)] == [f["key"] for f in outage],
    )

    # --- a held seat must never be proposed for a restart -------------------
    sheet = json.loads(IN_FORCE.read_text())
    for data in sheet["seats"].values():
        data.setdefault("unit", {})["hasLimitHold"] = True
        data["unit"]["available"] = True
        data["unit"]["activeState"] = "active"
    held = watchdog.evaluate(sheet, {"keys": {}, "restarts": {}}, watchdog.roster())
    open_findings = [f for f in held if f["evidence"].get("restartSafe") is not None]
    check(
        "a seat held on a live limit is marked restart-unsafe",
        open_findings and all(f["evidence"]["restartSafe"] is False for f in open_findings),
        f"{[(f['class'], f['evidence'].get('restartSafe')) for f in open_findings]}",
    )
    lim = by_class(held, "LIMIT")
    check(
        "a held fleet reports held seats, not killed ones",
        lim and lim[0]["evidence"].get("held") and not lim[0]["evidence"].get("killed"),
    )
    check(
        "a limit still in force is a notice, not a wake — a re-kick cannot run either",
        lim and lim[0]["severity"] == "notice",
        str(lim[0]["severity"]) if lim else "no LIMIT",
    )

    # The same seats with the same hold, but after the window reset: the veto
    # must lift. A check that can only ever say "unsafe" is not a check.
    after = json.loads(OUTAGE.read_text())
    for data in after["seats"].values():
        data.setdefault("unit", {})["hasLimitHold"] = True
        data["unit"]["available"] = True
        data["unit"]["activeState"] = "active"
    lifted = watchdog.evaluate(after, {"keys": {}, "restarts": {}}, watchdog.roster())
    lifted_open = [f for f in lifted if f["evidence"].get("restartSafe") is not None]
    check(
        "once the window resets the restart veto lifts",
        lifted_open and all(f["evidence"]["restartSafe"] is True for f in lifted_open),
        str([(f["class"], f["evidence"].get("restartSafe")) for f in lifted_open]),
    )

    # --- the relay classes, and the false positive that hid in them ---------
    # STRANDED_HANDOFF once fired on wren, which had in fact answered. A seat
    # publishes in the MIDDLE of its turn and its index row is written after it
    # returns, so "published since the turn finished" is a window the answer
    # can never land in: wren replied at 15:22:35 and its turn closed at
    # 15:22:44.9. The first fix was a five-second grace, and five seconds is a
    # number, not a reason. The anchor is the turn's start.
    relay = judge(RELAY)
    check(
        "relay: a healthy fleet raises nothing",
        relay == [],
        str([(f["class"], f["evidence"].get("seat")) for f in relay]),
    )

    # And the other half: with the reply deleted from the same bytes, the same
    # detector must fire. A check that cannot be made to fail proves nothing.
    sheet = json.loads(RELAY.read_text())
    victim = removed = None
    for seat, data in sheet["seats"].items():
        if data["openTurns"] or not data.get("recentTurns"):
            continue
        for turn in data["recentTurns"]:
            if turn["outcome"] != "ok" or not turn.get("channelId"):
                continue
            pub = (watchdog.roster().get(seat) or {}).get("pubkey")
            rows = sheet["relay"]["messages"].get(turn["channelId"], [])
            mine = [
                m for m in rows
                if m.get("pubkey") == pub
                and m.get("created_at", 0) >= (turn.get("startedAt") or 0)
            ]
            if mine:
                for m in mine:
                    rows.remove(m)
                victim, removed = seat, len(mine)
                break
        if victim:
            break
    check("a stranding case could be constructed from the live sheet", bool(victim))
    if victim:
        stranded = [
            f
            for f in watchdog.evaluate(sheet, {"keys": {}, "restarts": {}}, watchdog.roster())
            if f["class"] == "STRANDED_HANDOFF"
        ]
        check(
            f"relay: deleting {victim}'s {removed} repl(y/ies) makes it stranded",
            any(f["evidence"]["seat"] == victim for f in stranded),
            str([f["evidence"]["seat"] for f in stranded]),
        )
        check(
            "a stranded finding carries an openable link to the thread",
            all(
                f["evidence"].get("link", "").startswith("buzz://message?channel=")
                for f in stranded
            ),
        )

    # --- collect() itself, which no fixture can exercise --------------------
    # The fixtures are sheets, so they test evaluate() and nothing else. Both
    # of the real collection bugs — UUID ordering, and reading only the last
    # record of a file — live in collect() and survived the entire fixture
    # suite untouched. These read the body's own logs, so they only run where
    # those logs are.
    if not (watchdog.TURN_ROOT / "aldrin" / "turns" / "2026-09-22").is_dir():
        skip("collect(): finds the 2026-09-22 limit report", "hip turn logs not present")
    else:
        at = watchdog.parse_ts("2026-09-22T00:52:00Z")
        report = watchdog.latest_limit_report(at)
        check("collect(): a rate-limit report is found at all", report is not None)
        if report:
            check(
                "collect(): it is the refusal, not an earlier quiet report",
                report["report"].get("status") == "rejected",
                str(report["report"].get("status")),
            )
            check(
                "collect(): with the real resetsAt",
                report["report"].get("resetsAt") == 1790038200,
                str(report["report"].get("resetsAt")),
            )
            check(
                "collect(): dated inside the outage, not after it",
                at - 21600 <= report["ts"] <= at,
                watchdog.iso(report["ts"]),
            )
        # The invariant the UUID-ordering bug actually breaks is not "a report
        # is found" — a stale one is still a report, and inside one window the
        # status and resetsAt of every report are identical, so asserting those
        # cannot see the difference. What the bug changes is WHICH report, and
        # a stale one is how a lifted limit goes on being reported as in force.
        # So: brute-force the true newest and require an exact match.
        newest = None
        for seat_dir in sorted(watchdog.TURN_ROOT.iterdir()):
            for path in (seat_dir / "turns").glob("*/*.jsonl"):
                hit = watchdog.report_in_file(path, at)
                if hit and (newest is None or hit["ts"] > newest["ts"]):
                    newest = hit | {"seat": seat_dir.name}
        check(
            "collect(): the report is the NEWEST one on the body, not merely one of them",
            newest is not None
            and report is not None
            and abs(report["ts"] - newest["ts"]) < 0.001,
            f"picked {watchdog.iso(report['ts']) if report else None} "
            f"({report['seat'] if report else None}), newest is "
            f"{watchdog.iso(newest['ts']) if newest else None} "
            f"({newest['seat'] if newest else None})",
        )

        # A live collection must agree with the fixture that was captured from
        # it, or --check is replaying something the collector no longer emits.
        live = watchdog.collect(at, "hip", historical=True)
        saved = json.loads(OUTAGE.read_text())
        check(
            "collect(): a fresh capture still matches the saved sheet",
            (live.get("limitReport") or {}).get("report")
            == (saved.get("limitReport") or {}).get("report"),
        )
        check(
            "collect(): the same seats are still seen as refused",
            {
                s_: len(d.get("limitTurns", []))
                for s_, d in live["seats"].items()
                if d.get("limitTurns")
            }
            == {
                s_: len(d.get("limitTurns", []))
                for s_, d in saved["seats"].items()
                if d.get("limitTurns")
            },
        )

    # --- file ordering, which real bytes happen not to exercise -------------
    # Turn files are named by UUID, so ordering them by name is not ordering
    # them by time. On hip's actual logs the two orders agree by coincidence —
    # the UUID-highest file is also the newest — so the mutation that restores
    # the original bug survives every test above. The property is about
    # ordering, so the case for it is constructed rather than captured.
    check_ordering()

    # --- suppression must bound the blast radius ----------------------------
    state = {"keys": {}, "restarts": {}}
    first = watchdog.suppress(judge(OUTAGE), state, 1790000000.0)
    second = watchdog.suppress(judge(OUTAGE), state, 1790000600.0)
    check("first tick raises every finding", len(first) == len(outage), str(len(first)))
    check("an unchanged second tick raises nothing", second == [], str(len(second)))

    print()
    if skipped:
        print(f"{len(skipped)} SKIPPED (not passed): {', '.join(skipped)}")
    if failures:
        print(f"{len(failures)} failed: {', '.join(failures)}")
        return 1
    print(f"all {len(sys.argv) and 'checks'} passed" if not skipped else "no failures")
    return 0


if __name__ == "__main__":
    sys.exit(main())

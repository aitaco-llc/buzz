#!/usr/bin/env python3
"""fleet-watchdog — deterministic stall detection for the aitaco agent fleet.

Every seat on a body is a `buzz-acp` process that is purely reactive: it runs
only when a relay subscription hands it a trigger. Nothing in that design
notices when a turn dies, when a handoff is never returned, or when the
provider refuses the whole account. Those stalls are silent, and the fleet sits
idle until a human happens to write into a channel.

This script is the instrument for that. It runs on a timer, reads the turn logs
`buzz-acp` already writes, and posts one message into #fleet-health when it
finds something. It never calls a model: a script cannot misread a log, and
every mention it does not send is a Claude-seat turn nobody has to pay for.

The three stages are deliberately separate, and the separation is the point:

    collect()   reads the world and returns a SHEET — raw evidence, no verdicts
    evaluate()  is a pure function of (sheet, state, now) -> findings
    render()    turns findings into the message

Because `evaluate` never touches the disk, a sheet saved today can be re-judged
by a later version of the script (`--check sheet.json`). That is what makes this
check able to fail on demand: the 2026-09-21 usage-limit outage is on disk, and
`--at` reconstructs the sheet for any past instant, so a detector can be shown
firing on the real bytes of a real incident rather than on a mutant.

Modes
-----
    watchdog.py --dry-run           collect, evaluate, print (posts nothing)
    watchdog.py --post              the timer's mode: post if there is anything
    watchdog.py --capture FILE      collect and save the sheet, judge nothing
    watchdog.py --check FILE        judge a saved sheet offline
    watchdog.py --at ISO8601        reconstruct the sheet as of a past instant

Exit codes: 0 clean, 10 findings raised, 1 bad input, 2 collection failure.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCHEMA_VERSION = 1

# ---------------------------------------------------------------------------
# Thresholds. Starting values, not measurements — tune from the first week of
# #fleet-health. Every one is overridable from the environment so a tuning pass
# does not need a commit.
# ---------------------------------------------------------------------------


def _secs(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


# A turn with no index row whose liveness record stopped ticking. Liveness ticks
# every 10s, so 5 minutes is thirty missed ticks: the process is gone or wedged.
ORPHAN_SECS = _secs("WATCHDOG_ORPHAN_SECS", 300)
# Liveness still ticking but the agent has read nothing. The turn is alive and
# doing nothing, which is a foreground poll or a hung child.
STALL_SECS = _secs("WATCHDOG_STALL_SECS", 1200)
# Past this a stalled turn stops being rock's to nudge and becomes the channel's.
STALL_ESCALATE_SECS = _secs("WATCHDOG_STALL_ESCALATE_SECS", 3600)
# Past this an orphan stops being actionable. The trigger is still lost, but the
# conversation has moved on and re-kicking a day-old ask does more harm than
# leaving it — the 2026-09-21 reboot left four of these and every one of them
# was overtaken by later work.
ORPHAN_MAX_AGE_SECS = _secs("WATCHDOG_ORPHAN_MAX_AGE_SECS", 86400)
# How long after a limit window's own resetsAt to wake rock. Not zero: the
# provider's clock and ours are not the same clock.
LIMIT_WAKE_GRACE_SECS = _secs("WATCHDOG_LIMIT_WAKE_GRACE_SECS", 60)
# A filling window worth one no-mention line.
LIMIT_WARN_UTIL = float(os.environ.get("WATCHDOG_LIMIT_WARN_UTIL", "0.8"))
# A seat that finished a turn answering a p-tag and then published nothing.
STRANDED_SECS = _secs("WATCHDOG_STRANDED_SECS", 900)
# A p-tag that never became a turn.
DROPPED_SECS = _secs("WATCHDOG_DROPPED_SECS", 300)
# A remote body whose presence has been stale this long.
BODY_OFFLINE_SECS = _secs("WATCHDOG_BODY_OFFLINE_SECS", 1800)
# How far back to read turn logs. Findings older than this are somebody's
# history, not this tick's business.
WINDOW_SECS = _secs("WATCHDOG_WINDOW_SECS", 7200)
# How far back to look for the provider's most recent rate-limit report. The
# report rides on every turn once a window is filling, so the newest one on the
# box is the fleet's current state — it does not matter which seat carried it.
LIMIT_LOOKBACK_SECS = _secs("WATCHDOG_LIMIT_LOOKBACK_SECS", 86400)
# Only ever read this much off the end of a turn file. Every record this script
# wants — the last liveness tick, the last read, the error that ended it — is at
# the end, and some turn files are tens of megabytes.
TAIL_BYTES = _secs("WATCHDOG_TAIL_BYTES", 262144)
# How far back to look for turns the provider refused. This has to outrun the
# general window: a five-hour limit kills work for five hours, and the wake
# fires when it lifts, so at that moment the earliest casualties are already
# further back than any sane scanning window. Getting this wrong is how the
# first draft reported "0 seats dead-lettered" for an outage that killed 32
# triggers.
LIMIT_TURN_LOOKBACK_SECS = _secs("WATCHDOG_LIMIT_TURN_LOOKBACK_SECS", 21600)

# How long after boot to stay quiet. A reboot orphans every in-flight turn by
# definition, so the first tick after one would report the reboot — to a chief
# of staff whose own seat has not finished starting. A mention that lands
# before a seat is listening is lost: buzz-acp replays only the five seconds
# before its process start. The grace lives here rather than in the timer
# because a timer's OnBootSec silently schedules nothing when the timer is
# enabled after it has already elapsed.
MIN_UPTIME_SECS = _secs("WATCHDOG_MIN_UPTIME_SECS", 300)

TURN_ROOT = Path(os.environ.get("WATCHDOG_TURN_ROOT", Path.home() / ".local/state/buzz-turns"))
STATE_PATH = Path(
    os.environ.get("WATCHDOG_STATE", Path.home() / ".local/state/fleet-watchdog/state.json")
)
HEALTH_CHANNEL = os.environ.get("WATCHDOG_CHANNEL", "f71dbb47-ff3f-4642-b623-7f48ab369ae5")
# Who gets woken. Findings are handed to the chief of staff, never to the seat
# they are about: a seat that cannot run cannot read a mention either.
ROCK_PUBKEY = os.environ.get(
    "WATCHDOG_WAKE_PUBKEY", "41243293dd98372825e2c57bb2b44a100c36809a4339cf9bd564c9c33f8d5d0c"
)
ROCK_NAME = os.environ.get("WATCHDOG_WAKE_NAME", "rock")

# The marker string that only a binary carrying buzz#58 contains. Probing the
# running binary for it beats keeping a sha-to-commit map: the map goes stale
# silently, and `/proc/<pid>/exe` is still readable after the file it came from
# has been replaced. A seat without this string spends its retry budget against
# an account-wide limit and then dead-letters the trigger — the work is GONE,
# which is a different finding from a seat that merely paused.
LIMIT_HOLD_MARKER = "holding the seat on a provider usage limit"


# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------


def uptime_secs() -> float | None:
    """Seconds since boot, or None where that cannot be read (macOS)."""
    try:
        return float(Path("/proc/uptime").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        pass
    try:
        out = subprocess.run(
            ["sysctl", "-n", "kern.boottime"], capture_output=True, text=True, timeout=10
        ).stdout
        sec = re.search(r"sec\s*=\s*(\d+)", out)
        if sec:
            return dt.datetime.now(dt.timezone.utc).timestamp() - float(sec.group(1))
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    return None


def parse_ts(value: str | None) -> float | None:
    """Seconds since epoch from a turn log's RFC3339 stamp, or None."""
    if not value:
        return None
    text = value.strip()
    # The logs write nanoseconds; fromisoformat wants at most microseconds.
    text = re.sub(r"(\.\d{6})\d+", r"\1", text)
    text = text.replace("Z", "+00:00")
    try:
        return dt.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return None


def human(secs: float | None) -> str:
    """A duration a person reads at a glance, not a raw second count."""
    if secs is None:
        return "?"
    secs = int(secs)
    if secs < 120:
        return f"{secs}s"
    if secs < 7200:
        return f"{secs // 60} min"
    return f"{secs / 3600:.1f} h"


def iso(ts: float | None) -> str | None:
    if ts is None:
        return None
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def day_keys(now: float, back_secs: int) -> list[str]:
    """The UTC day directories a window touches, newest first."""
    days, t = [], now
    while t > now - back_secs - 86400:
        key = dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%d")
        if key not in days:
            days.append(key)
        t -= 86400
    return days


# ---------------------------------------------------------------------------
# Log readers
# ---------------------------------------------------------------------------


def read_jsonl(path: Path) -> list[dict]:
    out = []
    try:
        with path.open("r", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return out


def tail_jsonl(path: Path, max_bytes: int = TAIL_BYTES) -> list[dict]:
    """The last whole JSON lines of a file, without reading the whole file.

    A partial first line after the seek is dropped on purpose: it is a record
    this script already has a later copy of, or one it does not need.
    """
    try:
        size = path.stat().st_size
        with path.open("rb") as fh:
            if size > max_bytes:
                fh.seek(size - max_bytes)
                fh.readline()
            blob = fh.read()
    except OSError:
        return []
    out = []
    for line in blob.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return out


def seats_on_disk() -> list[str]:
    if not TURN_ROOT.is_dir():
        return []
    return sorted(p.name for p in TURN_ROOT.iterdir() if (p / "index").is_dir())


# ---------------------------------------------------------------------------
# Unit state
# ---------------------------------------------------------------------------


def unit_state(seat: str, body: str) -> dict:
    """What the supervisor says about a seat, plus a probe of its binary.

    `historical` collection cannot know this — a past instant's unit state is
    not on disk — so every consumer must tolerate `available: False` rather
    than read a missing field as a fault.
    """
    if body != "hip":
        # launchd exposes far less than systemd. A metal seat's unit facts come
        # from that body's own copy of this script; from here it is unavailable.
        return {"available": False, "reason": f"body={body}"}
    try:
        out = subprocess.run(
            [
                "systemctl", "--user", "show", f"buzz-agent@{seat}.service",
                "-p", "ActiveState", "-p", "NRestarts", "-p", "MainPID",
                "-p", "ActiveEnterTimestamp",
            ],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return {"available": False, "reason": "systemctl failed"}
    props = dict(
        line.split("=", 1) for line in out.strip().splitlines() if "=" in line
    )
    pid = int(props.get("MainPID", "0") or 0)
    state = {
        "available": True,
        "activeState": props.get("ActiveState", ""),
        "nRestarts": int(props.get("NRestarts", "0") or 0),
        "mainPid": pid,
        "activeEnter": props.get("ActiveEnterTimestamp", ""),
        "activeEnterTs": systemd_ts(props.get("ActiveEnterTimestamp", "")),
    }
    state.update(binary_probe(pid))
    return state


def systemd_ts(value: str) -> float | None:
    """`Tue 2026-09-22 09:19:48 MDT` -> epoch seconds.

    Worth parsing because it answers the question that separates a live orphan
    from a cold one: a turn whose last liveness tick predates the unit's
    current start belonged to a process that has already been replaced.
    """
    if not value:
        return None
    try:
        out = subprocess.run(
            ["date", "-d", value, "+%s"], capture_output=True, text=True, timeout=10
        )
        return float(out.stdout.strip()) if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def binary_probe(pid: int) -> dict:
    """Which harness a seat is actually running, asked of the process itself.

    Reading `/proc/<pid>/exe` rather than `~/.local/bin/buzz-acp` is the whole
    point: installing a new binary does not change a running seat, so the file
    on disk answers a different question from the one being asked.
    """
    if pid <= 0:
        return {"exeSha256": None, "hasLimitHold": None}
    exe = f"/proc/{pid}/exe"
    sha = None
    try:
        sha = subprocess.run(
            ["sha256sum", exe], capture_output=True, text=True, timeout=30
        ).stdout.split()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        pass
    hold = None
    try:
        blob = subprocess.run(
            ["strings", exe], capture_output=True, text=True, timeout=60
        ).stdout
        hold = LIMIT_HOLD_MARKER in blob
    except (OSError, subprocess.SubprocessError):
        pass
    return {"exeSha256": sha, "hasLimitHold": hold}


# ---------------------------------------------------------------------------
# collect
# ---------------------------------------------------------------------------


def collect(now: float, body: str, historical: bool) -> dict:
    """Read the world into a sheet. No verdicts are reached here."""
    sheet = {
        "schemaVersion": SCHEMA_VERSION,
        "body": body,
        "now": now,
        "nowIso": iso(now),
        "historical": historical,
        "seats": {},
        "limitReport": None,
        "collectErrors": [],
    }
    for seat in seats_on_disk():
        try:
            sheet["seats"][seat] = collect_seat(seat, now, body, historical)
        except Exception as exc:  # a broken seat must not blind the others
            sheet["collectErrors"].append({"seat": seat, "error": repr(exc)})
    sheet["limitReport"] = latest_limit_report(now)
    return sheet


def collect_seat(seat: str, now: float, body: str, historical: bool) -> dict:
    root = TURN_ROOT / seat
    cutoff = now - WINDOW_SECS

    # Completed turns, from the index. Two windows: the short one everything
    # else uses, and a longer one that only failures are kept in, because a
    # usage limit's casualties outlive it.
    long_cutoff = now - max(WINDOW_SECS, LIMIT_TURN_LOOKBACK_SECS)
    indexed: dict[str, dict] = {}
    recent: list[dict] = []
    failures: list[dict] = []
    for day in day_keys(now, max(WINDOW_SECS, LIMIT_TURN_LOOKBACK_SECS)):
        for row in read_jsonl(root / "index" / f"{day}.jsonl"):
            tid = row.get("turnId")
            done = parse_ts(row.get("completedAt"))
            if not tid or done is None:
                continue
            if historical and done > now:
                continue  # the future, as of the instant being reconstructed
            indexed[tid] = row
            if done < long_cutoff:
                continue
            entry = {
                "turnId": tid,
                "outcome": row.get("outcome"),
                "scope": row.get("scope"),
                "channelId": row.get("channelId"),
                "completedAt": done,
                "startedAt": parse_ts(row.get("startedAt")),
                "triggeringEventIds": row.get("triggeringEventIds") or [],
                "path": row.get("path"),
                "events": row.get("events"),
            }
            if done >= cutoff:
                recent.append(entry)
            if entry["outcome"] != "ok":
                failures.append(entry)

    # Turn files with no index row are turns that never finished.
    open_turns = []
    for day in day_keys(now, WINDOW_SECS):
        for path in sorted(glob.glob(str(root / "turns" / day / "*.jsonl"))):
            tid = Path(path).stem
            if tid in indexed:
                continue
            info = open_turn_facts(Path(path), now, historical)
            if info is None:
                continue
            if info["startedAt"] is not None and info["startedAt"] < cutoff:
                # Started before the window. Still open, so still interesting:
                # an orphan from three hours ago is the worst kind.
                pass
            open_turns.append(info | {"turnId": tid, "path": path})

    # Why each failed turn ended, read off the tail of its own file. The index
    # row carries an outcome and nothing else, so the reason is never in it.
    # Classified once and shared, so a turn inside both windows is read once.
    classified: dict[str, dict] = {}
    for row in failures:
        if not row.get("path"):
            continue
        facts = error_facts(root / row["path"])
        classified[row["turnId"]] = facts
        row.update(facts)
    for row in recent:
        if row["turnId"] in classified:
            row.update(classified[row["turnId"]])
    limit_turns = [r for r in failures if r.get("errorKind") == "rate_limit"]

    # Routing verdicts, one per inbound event the seat saw.
    decisions = []
    for day in day_keys(now, WINDOW_SECS):
        for row in read_jsonl(root / "decisions" / f"{day}.jsonl"):
            ts = parse_ts(row.get("ts"))
            if ts is None or ts < cutoff or (historical and ts > now):
                continue
            decisions.append(
                {
                    "ts": ts,
                    "decision": row.get("decision"),
                    "eventId": row.get("eventId"),
                    "author": row.get("author"),
                    "channelId": row.get("channelId"),
                    "threadRoot": row.get("threadRoot"),
                    "kind": row.get("kind"),
                }
            )

    return {
        "unit": {"available": False, "reason": "historical"}
        if historical
        else unit_state(seat, body),
        "pubkey": (recent[0]["seat"] if recent and "seat" in recent[0] else None)
        or seat_pubkey(root, now),
        "openTurns": open_turns,
        "recentTurns": recent,
        "limitTurns": limit_turns,
        "decisions": decisions,
        "lastCompletedAt": max((r["completedAt"] for r in recent), default=None),
    }


def seat_pubkey(root: Path, now: float) -> str | None:
    for day in day_keys(now, LIMIT_LOOKBACK_SECS):
        rows = tail_jsonl(root / "index" / f"{day}.jsonl", 8192)
        for row in reversed(rows):
            if row.get("seat"):
                return row["seat"]
    return None


def open_turn_facts(path: Path, now: float, historical: bool) -> dict | None:
    """Last liveness tick and last agent read for an unfinished turn.

    Read from the tail, because a long turn's file is mostly `acp_read` records
    that nothing here cares about.
    """
    records = tail_jsonl(path)
    if not records:
        return None
    started = last_liveness = last_read = None
    channel = scope = None
    triggers: list[str] = []
    for rec in records:
        ts = parse_ts(rec.get("timestamp"))
        if historical and ts is not None and ts > now:
            continue
        kind = rec.get("kind")
        if rec.get("channelId"):
            channel = rec["channelId"]
        if started is None:
            started = parse_ts(rec.get("startedAt"))
        if kind == "turn_started":
            payload = rec.get("payload") or {}
            scope = payload.get("scope") or scope
            triggers = payload.get("triggeringEventIds") or triggers
        elif kind == "turn_liveness":
            last_liveness = ts if last_liveness is None else max(last_liveness, ts)
        elif kind == "acp_read":
            last_read = ts if last_read is None else max(last_read, ts)
    if started is None and last_liveness is None and last_read is None:
        return None
    return {
        "startedAt": started,
        "lastLiveness": last_liveness,
        "lastAcpRead": last_read,
        "channelId": channel,
        "scope": scope,
        "triggeringEventIds": triggers,
    }


def error_facts(path: Path) -> dict:
    """Classify a failed turn from its own tail.

    `errorKind` is structural — the adapter forwards the provider's own
    `data.errorKind` — so it is preferred over the prose, which is rendered for
    a human and changes with the week.
    """
    kind = text = None
    for rec in tail_jsonl(path):
        payload = rec.get("payload") or {}
        if rec.get("kind") == "acp_read":
            err = payload.get("error") or {}
            data = err.get("data") or {}
            if isinstance(data, dict) and data.get("errorKind"):
                kind = data["errorKind"]
                text = err.get("message") or text
        elif rec.get("kind") == "turn_error":
            text = payload.get("error") or text
    return {"errorKind": kind, "errorText": text}


def latest_limit_report(now: float) -> dict | None:
    """The newest `_claude/rateLimit` report anywhere on this body.

    A usage limit belongs to the ACCOUNT, so whichever seat happened to carry
    the most recent report speaks for all of them. The report rides on a
    `usage_update` notification on essentially every turn once a window starts
    filling, which is exactly why its mere PRESENCE means nothing — 1165 turn
    files on hip carry one. `status` is the discriminator: `allowed` is quiet,
    `allowed_warning` is a filling window, `rejected` is the limit in force.

    Two things here were wrong in the first draft and both were caught by
    replaying the 2026-09-21 outage, which this found nothing in:

      * turn files are named by UUID, so sorting by name is not sorting by
        time. They are ordered by mtime instead.
      * the report sits on a `usage_update` a few records before the end of a
        failed turn, not on the last record, so only inspecting the final line
        of each file misses every one of them.
    """
    best = None
    for seat in seats_on_disk():
        found = None
        for day in day_keys(now, LIMIT_LOOKBACK_SECS):
            paths = [Path(p) for p in glob.glob(str(TURN_ROOT / seat / "turns" / day / "*.jsonl"))]
            paths.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)
            for path in paths:
                if path.stat().st_mtime < now - LIMIT_LOOKBACK_SECS - 3600:
                    break  # this day is exhausted; older files cannot be newer
                hit = report_in_file(path, now)
                if hit and (found is None or hit["ts"] > found["ts"]):
                    found = hit | {"seat": seat}
                if found:
                    break  # newest-first, so the first file with one wins
            if found:
                break
        if found and (best is None or found["ts"] > best["ts"]):
            best = found
    return best


def report_in_file(path: Path, now: float) -> dict | None:
    """The newest rate-limit report in one turn file at or before `now`."""
    for rec in reversed(tail_jsonl(path)):
        ts = parse_ts(rec.get("timestamp"))
        if ts is None or ts > now or ts < now - LIMIT_LOOKBACK_SECS:
            continue
        payload = rec.get("payload") or {}
        params = payload.get("params")
        if not isinstance(params, dict):
            continue
        update = params.get("update")
        if not isinstance(update, dict):
            continue
        report = (update.get("_meta") or {}).get("_claude/rateLimit")
        if isinstance(report, dict):
            return {"ts": ts, "report": report}
    return None


# ---------------------------------------------------------------------------
# Roster
# ---------------------------------------------------------------------------


def roster(repo_root: Path | None = None) -> dict[str, dict]:
    """name -> {body, pubkey}, from the two files that already own this.

    `deploy/seats.conf` says so in its own header: every script reads it and
    nothing else lists seats. Duplicating the roster here would be a third
    place to forget.
    """
    seats: dict[str, dict] = {}
    conf = Path(
        os.environ.get("WATCHDOG_SEATS_CONF", Path.home() / "dev/agents/deploy/seats.conf")
    )
    try:
        for line in conf.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 2:
                seats[parts[0]] = {"body": parts[1], "pubkey": None}
    except OSError:
        pass
    keys = Path(
        os.environ.get("WATCHDOG_PUBKEYS", Path.home() / ".config/buzz-agents/pubkeys.txt")
    )
    try:
        for line in keys.read_text().splitlines():
            parts = line.split()
            if len(parts) == 2:
                seats.setdefault(parts[0], {"body": None, "pubkey": None})
                seats[parts[0]]["pubkey"] = parts[1]
    except OSError:
        pass
    return seats


# ---------------------------------------------------------------------------
# Relay layer (optional). Zero model calls; these are plain CLI reads.
# ---------------------------------------------------------------------------


def buzz_json(args: list[str], timeout: int = 45):
    try:
        proc = subprocess.run(
            ["buzz", *args], capture_output=True, text=True, timeout=timeout
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def collect_relay(sheet: dict, people: dict[str, dict]) -> None:
    """Add presence and the channel traffic the disk-only classes cannot see.

    A stranded handoff is invisible on disk: the turn log records what the seat
    READ, never what it published. The only witness to "B finished and said
    nothing" is the channel.

    This never SSHes. A sleeping Mac must not be able to hang the tick, and
    `agentctl list` pays an 8s SSH timeout per body to learn what relay
    presence already knows.
    """
    cutoff = int(sheet["now"] - WINDOW_SECS)
    channels = {
        t["channelId"]
        for seat in sheet["seats"].values()
        for t in seat["recentTurns"] + seat["openTurns"]
        if t.get("channelId")
    }
    messages: dict[str, list] = {}
    for channel in sorted(channels):
        rows = buzz_json(["messages", "get", "--channel", channel, "--since", str(cutoff)])
        if isinstance(rows, list):
            messages[channel] = rows
    sheet["relay"] = {"messages": messages, "presence": {}}

    remote = [
        name
        for name, info in people.items()
        if info.get("pubkey") and info.get("body") and info["body"] != sheet["body"]
    ]
    if remote:
        keys = ",".join(people[n]["pubkey"] for n in remote)
        rows = buzz_json(["users", "presence", "--pubkeys", keys])
        if isinstance(rows, list):
            by_key = {r.get("pubkey"): r for r in rows}
            for name in remote:
                sheet["relay"]["presence"][name] = by_key.get(people[name]["pubkey"])


def tags_of(event: dict, letter: str) -> list[str]:
    return [t[1] for t in event.get("tags", []) if len(t) >= 2 and t[0] == letter]


def thread_root_of(event: dict) -> str | None:
    """The root this event hangs from, or None for a top-level post."""
    es = [t for t in event.get("tags", []) if len(t) >= 2 and t[0] == "e"]
    if not es:
        return None
    for tag in es:
        if len(tag) >= 4 and tag[3] == "root":
            return tag[1]
    return es[0][1]


# ---------------------------------------------------------------------------
# evaluate — pure. Nothing below this line reads the disk or the relay.
# ---------------------------------------------------------------------------


def finding(cls: str, key: str, severity: str, summary: str, **evidence) -> dict:
    return {
        "class": cls,
        "key": key,
        "severity": severity,  # wake | notice
        "summary": summary,
        "evidence": evidence,
    }


def evaluate(sheet: dict, state: dict, people: dict[str, dict]) -> list[dict]:
    now = sheet["now"]
    out: list[dict] = []
    out += eval_limit(sheet, now)
    out += eval_turns(sheet, now)
    out += eval_units(sheet, state, now)
    if sheet.get("relay"):
        out += eval_stranded(sheet, people, now)
        out += eval_dropped(sheet, people, now)
        out += eval_body_offline(sheet, people, now)
    return out


def eval_limit(sheet: dict, now: float) -> list[dict]:
    """The account's usage window, and who lost work to it.

    Two findings, not one, because they call for opposite actions. A seat whose
    harness carries buzz#58 HELD its triggers: they resume by themselves and
    re-kicking them would double the work. A seat whose harness predates #58
    spent its retry budget and dead-lettered: that work is gone and only a
    re-kick brings it back. Telling rock "the limit lifted" without saying
    which seats are in which group is telling it nothing it can act on.
    """
    report = sheet.get("limitReport")
    if not report:
        return []
    rep = report["report"]
    status = rep.get("status")
    window = rep.get("rateLimitType") or "unknown"
    resets = rep.get("resetsAt")
    out = []

    if status == "rejected" and resets:
        # Three groups, not two. "We could not probe the binary" must never
        # render as "this seat threw the work away": unknown is its own answer,
        # and rock decides what to do about it rather than being told a guess.
        held, killed, unknown = [], [], []
        for seat, data in sheet["seats"].items():
            limited = [
                t
                for t in data.get("limitTurns", [])
                if t["completedAt"] >= now - LIMIT_TURN_LOOKBACK_SECS
            ]
            if not limited:
                continue
            has_hold = (data.get("unit") or {}).get("hasLimitHold")
            row = {"seat": seat, "turns": len(limited), "hasLimitHold": has_hold}
            (held if has_hold is True else killed if has_hold is False else unknown).append(row)
        # Before the window resets there is nothing for rock to do: a re-kick
        # cannot run either. The wake is scheduled for after it lifts.
        if now < resets + LIMIT_WAKE_GRACE_SECS:
            out.append(
                finding(
                    "LIMIT", f"limit:{window}:{resets}", "notice",
                    f"Account is refusing on the {window} window; it resets {iso(resets)}. "
                    f"Nothing to do until then — a re-kick cannot run either.",
                    window=window, resetsAt=resets, resetsAtIso=iso(resets),
                    held=held, killed=killed, unknown=unknown, reportSeat=report["seat"],
                    reportedAt=iso(report["ts"]),
                )
            )
        else:
            out.append(
                finding(
                    "LIMIT", f"limit-lifted:{window}:{resets}", "wake",
                    f"The {window} window reset at {iso(resets)}. "
                    + (
                        f"{len(killed)} seat(s) dead-lettered work that will not come back "
                        "on its own."
                        if killed
                        else f"{len(unknown)} seat(s) were refused but their harness could "
                        "not be probed — check before assuming the work resumed."
                        if unknown
                        else "Held work resumes by itself; nothing to re-kick."
                    ),
                    window=window, resetsAt=resets, resetsAtIso=iso(resets),
                    held=held, killed=killed, unknown=unknown,
                )
            )
        if killed:
            out.append(
                finding(
                    "LIMIT_DEADLETTER",
                    f"deadletter:{window}:{resets}", "wake",
                    f"{sum(k['turns'] for k in killed)} trigger(s) across {len(killed)} seat(s) "
                    "were discarded, not held — those harnesses predate buzz#58. They need "
                    "re-kicking by hand; held seats do not.",
                    window=window, resetsAt=resets, killed=killed,
                )
            )
    elif status == "allowed_warning":
        util = rep.get("utilization") or 0.0
        if util >= LIMIT_WARN_UTIL and resets:
            out.append(
                finding(
                    "LIMIT_WARNING", f"warn:{window}:{resets}", "notice",
                    f"The {window} window is {util:.0%} full; it resets {iso(resets)}.",
                    window=window, utilization=util, resetsAt=resets,
                    resetsAtIso=iso(resets),
                )
            )
    return out


def eval_turns(sheet: dict, now: float) -> list[dict]:
    """Turns that started and never came back.

    Liveness ticks every 10s for as long as the harness holds the turn, so it
    separates the two shapes cleanly: no ticks means the process is gone or
    wedged (ORPHAN), ticks with no reads means the process is fine and the turn
    is not moving (STALLED).
    """
    out = []
    for seat, data in sheet["seats"].items():
        held = seat_is_held(data, sheet, now)
        for turn in data["openTurns"]:
            live, read = turn.get("lastLiveness"), turn.get("lastAcpRead")
            started = turn.get("startedAt")
            age = now - started if started else None
            base = dict(
                seat=seat, turnId=turn["turnId"], channelId=turn.get("channelId"),
                scope=turn.get("scope"), startedAt=iso(started),
                ageSecs=int(age) if age else None,
                lastLiveness=iso(live), lastAcpRead=iso(read),
                triggeringEventIds=turn.get("triggeringEventIds") or [],
                # A held seat's queue is in memory and nowhere else. Restarting
                # it destroys exactly the triggers buzz#58 preserved, so the
                # finding carries the veto rather than leaving it to be
                # remembered.
                restartSafe=not held,
                heldOnLimit=held,
            )
            if live is None or now - live > ORPHAN_SECS:
                silent = now - live if live else None
                if silent is not None and silent > ORPHAN_MAX_AGE_SECS:
                    continue
                started_unit = ((data.get("unit") or {}).get("activeEnterTs"))
                superseded = bool(live and started_unit and live < started_unit)
                out.append(
                    finding(
                        "ORPHAN", f"orphan:{seat}:{turn['turnId']}", "wake",
                        f"{seat} has a turn open with no liveness tick for {human(silent)}"
                        + (
                            " — its process was replaced by a restart, so nothing will "
                            "resume it."
                            if superseded
                            else " — the process that owned it is gone."
                        ),
                        supersededByRestart=superseded,
                        silentFor=human(silent),
                        **base,
                    )
                )
            elif read is not None and now - read > STALL_SECS:
                quiet = int(now - read)
                out.append(
                    finding(
                        "STALLED_TURN", f"stalled:{seat}:{turn['turnId']}",
                        "wake" if quiet > STALL_ESCALATE_SECS else "notice",
                        f"{seat}'s turn is alive but has read nothing for {human(quiet)}.",
                        quietSecs=quiet, **base,
                    )
                )
    return out


def seat_is_held(data: dict, sheet: dict, now: float) -> bool:
    """Is this seat paused on a usage limit right now?

    True only when the harness can actually hold (buzz#58) AND the account is
    refusing AND the window has not reset. A seat without the hold is not held;
    its work was discarded, which is a different fact with a different remedy.
    """
    report = sheet.get("limitReport")
    if not report or report["report"].get("status") != "rejected":
        return False
    resets = report["report"].get("resetsAt")
    if resets and now >= resets:
        return False
    return bool((data.get("unit") or {}).get("hasLimitHold"))


def eval_units(sheet: dict, state: dict, now: float) -> list[dict]:
    out = []
    for seat, data in sheet["seats"].items():
        unit = data.get("unit") or {}
        if not unit.get("available"):
            continue
        if unit.get("activeState") != "active":
            out.append(
                finding(
                    "UNIT_DOWN", f"unit:{seat}", "wake",
                    f"buzz-agent@{seat}.service is {unit.get('activeState')}.",
                    seat=seat, activeState=unit.get("activeState"),
                    nRestarts=unit.get("nRestarts"),
                )
            )
            continue
        prior = (state.get("restarts") or {}).get(seat)
        now_n = unit.get("nRestarts", 0)
        if prior and now - prior["ts"] <= 3600 and now_n - prior["n"] > 2:
            out.append(
                finding(
                    "UNIT_FLAPPING", f"flap:{seat}:{now_n}", "wake",
                    f"buzz-agent@{seat}.service restarted {now_n - prior['n']} times in the last hour.",
                    seat=seat, nRestarts=now_n, wasRestarts=prior["n"],
                )
            )
    return out


#: Index outcomes that mean the turn is over and the seat is not coming back to
#: it. `ok` is a turn that reached its own end; the other three were cut off
#: (buzz-acp `pool::ok_outcome_label`) and are if anything MORE likely to have
#: left an ask unanswered — `exhausted` is the audited 2026-09-22 shape, where
#: rock spent a whole tool-call budget on Lloyd's question and published
#: nothing. They were all written `ok` before that change, which is why this
#: reads a set rather than a string: an outcome not listed here (an error, a
#: timeout, a dead letter) has its own detectors and a retry may still run.
FINISHED_OUTCOMES = {"ok", "exhausted", "limited", "refused"}


def eval_stranded(sheet: dict, people: dict, now: float) -> list[dict]:
    """A finished handoff that was never returned.

    Work only happens inside turns. So if B's index says a turn answering A's
    p-tag is over, B has no turn open, and B has published nothing in that
    thread since, then B is done and A is still waiting. That is the 2026-09-19
    shape: three green PRs sat unmerged for 70 minutes because the callback
    mention was never sent.

    A cut-off turn normally posts its own `⚠️` notice into that thread, signed
    with the seat's key, and that publication suppresses this finding — which is
    the right order: the harness answers in seconds, this answers in minutes.
    This stays as the backstop for the case where the notice never went out.
    """
    msgs = sheet["relay"]["messages"]
    by_id = {m["id"]: m for ch in msgs.values() for m in ch}
    out = []
    for seat, data in sheet["seats"].items():
        pub = (people.get(seat) or {}).get("pubkey")
        if not pub or data["openTurns"]:
            continue  # a seat mid-turn has not finished anything yet
        for turn in data["recentTurns"]:
            if turn["outcome"] not in FINISHED_OUTCOMES or not turn.get("channelId"):
                continue
            if now - turn["completedAt"] < STRANDED_SECS:
                continue
            channel = turn["channelId"]
            for trigger_id in turn["triggeringEventIds"]:
                trigger = by_id.get(trigger_id)
                if not trigger or trigger.get("pubkey") == pub:
                    continue
                if pub not in tags_of(trigger, "p"):
                    continue
                root = thread_root_of(trigger) or trigger_id
                # Anchored to when the turn STARTED, not when it ended. A
                # seat publishes in the middle of its turn and the index row is
                # written after it returns, so "published since it finished" is
                # a window that the answer can never fall inside: wren replied
                # to this thread at 15:22:35 and its turn closed at 15:22:44.9,
                # and a five-second grace still called that stranded.
                since = turn.get("startedAt") or turn["completedAt"]
                published = [
                    m
                    for m in msgs.get(channel, [])
                    if m.get("pubkey") == pub
                    and m.get("created_at", 0) >= since
                    and (thread_root_of(m) or m["id"]) == root
                ]
                if published:
                    continue
                asker = next(
                    (n for n, i in people.items() if i.get("pubkey") == trigger.get("pubkey")),
                    trigger.get("pubkey", "")[:8],
                )
                out.append(
                    finding(
                        "STRANDED_HANDOFF", f"stranded:{seat}:{trigger_id}", "wake",
                        f"{seat} finished the turn {asker} handed it and published nothing "
                        f"in that thread; {asker} has been waiting "
                        f"{int((now - turn['completedAt']) / 60)} min.",
                        seat=seat, waitingOn=asker, channelId=channel,
                        threadRoot=root, triggerEventId=trigger_id,
                        finishedAt=iso(turn["completedAt"]),
                        link=f"buzz://message?channel={channel}&id={root}",
                    )
                )
    return out


NAME_RE = re.compile(r"(?<![\w`])@([a-z][a-z0-9-]{1,31})\b")


def eval_dropped(sheet: dict, people: dict, now: float) -> list[dict]:
    """An `@name` that never woke anybody.

    Two shapes, one finding. Either the message carries no `p` tag for the name
    it addresses — the client-side bug where a follow-up in a thread renders
    the mention but drops the tag — or the tag is there and the seat's own
    decision log never turned it into a turn.
    """
    out = []
    for channel, rows in sheet["relay"]["messages"].items():
        for msg in rows:
            age = now - msg.get("created_at", now)
            if age < DROPPED_SECS or age > WINDOW_SECS:
                continue
            ptags = tags_of(msg, "p")
            for name in set(NAME_RE.findall(msg.get("content", ""))):
                info = people.get(name)
                if not info or not info.get("pubkey"):
                    continue
                pub = info["pubkey"]
                if msg.get("pubkey") == pub:
                    continue
                if pub not in ptags:
                    out.append(
                        finding(
                            "DROPPED_TRIGGER", f"dropped-tag:{msg['id']}:{name}", "wake",
                            f"A message addresses @{name} in its text but carries no `p` tag "
                            f"for it, so {name}'s seat was never woken.",
                            seat=name, channelId=channel, eventId=msg["id"],
                            authorPubkey=msg.get("pubkey"), reason="no p tag",
                            link=f"buzz://message?channel={channel}&id={msg['id']}",
                        )
                    )
                    continue
                data = sheet["seats"].get(name)
                if data is None:
                    continue  # another body's seat; its own watchdog owns this
                seen = any(
                    d["eventId"] == msg["id"] and d["decision"] == "queued"
                    for d in data["decisions"]
                )
                ran = any(
                    msg["id"] in t["triggeringEventIds"]
                    for t in data["recentTurns"] + data["openTurns"]
                )
                if not seen and not ran:
                    out.append(
                        finding(
                            "DROPPED_TRIGGER", f"dropped-turn:{msg['id']}:{name}", "wake",
                            f"@{name} was p-tagged {int(age / 60)} min ago and its seat "
                            f"neither queued nor ran the trigger.",
                            seat=name, channelId=channel, eventId=msg["id"],
                            reason="p tag present, no turn",
                            link=f"buzz://message?channel={channel}&id={msg['id']}",
                        )
                    )
    return out


def eval_body_offline(sheet: dict, people: dict, now: float) -> list[dict]:
    """A body that is not there, with work waiting on it.

    Presence alone is not a finding — a Mac asleep with nothing assigned is
    somebody's evening, not an incident. It becomes one when a mention is
    sitting unanswered, because only a person can open the lid.
    """
    out = []
    msgs = sheet["relay"]["messages"]
    for name, pres in (sheet["relay"].get("presence") or {}).items():
        pub = (people.get(name) or {}).get("pubkey")
        if not pub:
            continue
        stale = pres is None or pres.get("status") != "online"
        seen = (pres or {}).get("updated_at")
        if not stale or (seen and now - seen < BODY_OFFLINE_SECS):
            continue
        waiting = [
            (ch, m)
            for ch, rows in msgs.items()
            for m in rows
            if pub in tags_of(m, "p")
            and m.get("pubkey") != pub
            and not any(
                r.get("pubkey") == pub and r.get("created_at", 0) > m.get("created_at", 0)
                for r in rows
            )
        ]
        if not waiting:
            continue
        channel, msg = waiting[0]
        out.append(
            finding(
                "BODY_OFFLINE", f"offline:{name}:{msg['id']}", "wake",
                f"{name} has been offline since {iso(seen)} with {len(waiting)} "
                f"unanswered mention(s). Only a person can wake that body.",
                seat=name, body=(people.get(name) or {}).get("body"),
                lastSeen=iso(seen), waiting=len(waiting),
                link=f"buzz://message?channel={channel}&id={msg['id']}",
            )
        )
    return out


# ---------------------------------------------------------------------------
# State and the escalation ladder
# ---------------------------------------------------------------------------


def load_state() -> dict:
    try:
        return json.loads(STATE_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return {"keys": {}, "restarts": {}}


def save_state(state: dict) -> None:
    try:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(state, indent=1, sort_keys=True))
        tmp.replace(STATE_PATH)
    except OSError as exc:
        print(f"watchdog: could not save state: {exc}", file=sys.stderr)


def suppress(findings: list[dict], state: dict, now: float) -> list[dict]:
    """Raise each incident once, and again only when it climbs the ladder.

    Blast radius is the thing this function exists to bound. A stall does not
    clear itself just because a timer fired, so re-posting an unchanged finding
    every ten minutes would wake rock 144 times for one incident. A key is
    posted on first sight and then only when its severity increases — notice to
    wake — which is the only change that asks for a different action.
    """
    keys = state.setdefault("keys", {})
    fresh = []
    for item in findings:
        prior = keys.get(item["key"])
        if prior is None:
            item["firstSeen"] = now
            fresh.append(item)
        elif item["severity"] == "wake" and prior.get("severity") != "wake":
            item["firstSeen"] = prior.get("firstSeen", now)
            item["escalated"] = True
            fresh.append(item)
        keys[item["key"]] = {
            "severity": item["severity"],
            "class": item["class"],
            "firstSeen": (prior or {}).get("firstSeen", now),
            "lastSeen": now,
            "posted": now if (prior is None or item in fresh) else (prior or {}).get("posted"),
        }
    # Keys nobody has seen for a day are closed incidents.
    for key in [k for k, v in keys.items() if now - (v.get("lastSeen") or 0) > 86400]:
        keys.pop(key, None)
    return fresh


def record_restarts(sheet: dict, state: dict) -> None:
    restarts = state.setdefault("restarts", {})
    for seat, data in sheet["seats"].items():
        unit = data.get("unit") or {}
        if unit.get("available"):
            restarts[seat] = {"n": unit.get("nRestarts", 0), "ts": sheet["now"]}


def rock_is_mid_turn(sheet: dict) -> bool:
    """Is the seat we are about to wake already awake on this?

    Posting into an incident rock is actively working costs it a whole extra
    turn to read a finding it already has. Cheap to check: an open turn file in
    the health channel with no index row is a turn in flight.
    """
    data = sheet["seats"].get("rock")
    if not data:
        return False
    return any(t.get("channelId") == HEALTH_CHANNEL for t in data["openTurns"])


# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------

ORDER = [
    "LIMIT_DEADLETTER", "LIMIT", "UNIT_DOWN", "ORPHAN", "STRANDED_HANDOFF",
    "DROPPED_TRIGGER", "BODY_OFFLINE", "UNIT_FLAPPING", "STALLED_TURN",
    "LIMIT_WARNING",
]


def render(findings: list[dict], sheet: dict) -> str:
    """One message, evidence inline.

    Rock should never have to open a log to act on this. Everything it needs —
    the seat, the scope, the trigger id, the reset instant, whether a restart
    would destroy held work — is in the text, because reading the logs is a
    second turn and the whole point of a deterministic detector is to spend
    exactly one.
    """
    wake = [f for f in findings if f["severity"] == "wake"]
    lines = []
    head = f"**{len(findings)} finding(s)** on `{sheet['body']}` at {sheet['nowIso']}."
    if wake:
        lines.append(f"@{ROCK_NAME} {head}")
    else:
        lines.append(head + " No action needed; posted without a mention.")
    lines.append("")

    findings = sorted(
        findings, key=lambda f: (ORDER.index(f["class"]) if f["class"] in ORDER else 99)
    )
    for item in findings:
        mark = "" if item["severity"] == "wake" else " _(notice)_"
        esc = " _(escalated)_" if item.get("escalated") else ""
        lines.append(f"**{item['class']}**{mark}{esc} — {item['summary']}")
        for line in evidence_lines(item):
            lines.append(f"  - {line}")
        lines.append("")
    lines.append(
        f"_Deterministic scan, no model involved. Key `{item_key_hint(findings)}`. "
        f"Each incident is raised once and again only if it escalates._"
    )
    return "\n".join(lines)


def item_key_hint(findings: list[dict]) -> str:
    return findings[0]["key"] if findings else "-"


def evidence_lines(item: dict) -> list[str]:
    ev = item["evidence"]
    out = []
    if ev.get("link"):
        out.append(ev["link"])
    if ev.get("seat"):
        bits = [f"seat `{ev['seat']}`"]
        if ev.get("scope"):
            bits.append(f"scope `{ev['scope']}`")
        if ev.get("turnId"):
            bits.append(f"turn `{ev['turnId'][:8]}`")
        if ev.get("ageSecs"):
            bits.append(f"open {human(ev['ageSecs'])}")
        out.append(", ".join(bits))
    if ev.get("triggeringEventIds"):
        out.append(
            "triggers " + ", ".join(f"`{t[:8]}`" for t in ev["triggeringEventIds"][:4])
        )
    if ev.get("supersededByRestart"):
        out.append(
            "the seat has restarted since, so this is a lost trigger rather than a "
            "wedged process — re-kick it or let it go, but do not restart anything"
        )
    if ev.get("restartSafe") is False:
        out.append(
            "**do not restart** — this seat is held on a usage limit and its queue is "
            "in memory only; a restart discards every trigger the hold is preserving"
        )
    if ev.get("resetsAtIso"):
        out.append(f"window `{ev.get('window')}` resets {ev['resetsAtIso']}")
    if ev.get("held"):
        out.append(
            "held (resumes by itself, do not re-kick): "
            + ", ".join(f"`{h['seat']}`×{h['turns']}" for h in ev["held"])
        )
    if ev.get("unknown"):
        out.append(
            "harness not probed (state unknown, do not assume either way): "
            + ", ".join(f"`{u['seat']}`×{u['turns']}" for u in ev["unknown"])
        )
    if ev.get("killed"):
        out.append(
            "**dead-lettered** (work is gone, needs a re-kick): "
            + ", ".join(f"`{k['seat']}`×{k['turns']}" for k in ev["killed"])
        )
    if ev.get("lastAcpRead"):
        out.append(f"last agent read {ev['lastAcpRead']}")
    if ev.get("lastSeen"):
        out.append(f"last seen {ev['lastSeen']}")
    if ev.get("reason"):
        out.append(f"reason: {ev['reason']}")
    return out


# ---------------------------------------------------------------------------
# post
# ---------------------------------------------------------------------------


def post(text: str, mention: bool) -> dict | None:
    args = ["messages", "send", "--channel", HEALTH_CHANNEL, "--content", "-"]
    if mention:
        args += ["--mention", ROCK_PUBKEY]
    try:
        proc = subprocess.run(
            ["buzz", *args], input=text, capture_output=True, text=True, timeout=60
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"watchdog: post failed: {exc}", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print(f"watchdog: post rejected: {proc.stderr.strip()}", file=sys.stderr)
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--post", action="store_true", help="post findings (the timer's mode)")
    mode.add_argument("--dry-run", action="store_true", help="print, post nothing")
    mode.add_argument("--capture", metavar="FILE", help="save a sheet and judge nothing")
    mode.add_argument("--check", metavar="FILE", help="judge a saved sheet offline")
    mode.add_argument(
        "--seed-state", action="store_true",
        help="record what is currently wrong without posting it — the first-install step, "
             "so a cold start does not wake rock with a week of settled history",
    )
    ap.add_argument("--at", metavar="ISO8601", help="reconstruct the sheet as of a past instant")
    ap.add_argument("--body", default=os.environ.get("WATCHDOG_BODY", "hip"))
    ap.add_argument("--relay", action="store_true", help="include relay-backed classes")
    ap.add_argument("--pulse", action="store_true", help="post a no-mention line when clean")
    ap.add_argument("--no-state", action="store_true", help="ignore and do not write state")
    ap.add_argument("--json", action="store_true", help="print findings as JSON")
    ap.add_argument(
        "--min-uptime", type=int, default=MIN_UPTIME_SECS,
        help="stay quiet for this many seconds after boot (0 disables)",
    )
    args = ap.parse_args(argv)

    people = roster()

    if args.check:
        try:
            sheet = json.loads(Path(args.check).read_text())
        except (OSError, json.JSONDecodeError) as exc:
            print(f"watchdog: cannot read sheet: {exc}", file=sys.stderr)
            return 1
        if sheet.get("schemaVersion") != SCHEMA_VERSION:
            print(
                f"watchdog: sheet is schema {sheet.get('schemaVersion')}, "
                f"this build reads {SCHEMA_VERSION}",
                file=sys.stderr,
            )
        state = {"keys": {}, "restarts": {}}
        findings = evaluate(sheet, state, people)
        return report(findings, sheet, args, post_ok=False)

    if args.post and args.min_uptime:
        up = uptime_secs()
        if up is not None and up < args.min_uptime:
            print(
                f"watchdog: {int(up)}s since boot, under the {args.min_uptime}s grace — "
                "a reboot orphans every in-flight turn and the seats are still starting"
            )
            return 0

    now = dt.datetime.now(dt.timezone.utc).timestamp()
    historical = False
    if args.at:
        parsed = parse_ts(args.at)
        if parsed is None:
            print(f"watchdog: cannot parse --at {args.at!r}", file=sys.stderr)
            return 1
        now, historical = parsed, True

    sheet = collect(now, args.body, historical)
    if args.relay and not historical:
        # Historical reconstruction cannot ask the relay what it looked like an
        # hour ago, so the relay classes are simply absent from a past sheet
        # rather than silently evaluated against present-day traffic.
        collect_relay(sheet, people)

    if args.capture:
        Path(args.capture).write_text(json.dumps(sheet, indent=1, sort_keys=True))
        print(f"wrote {args.capture} ({Path(args.capture).stat().st_size} bytes)")
        return 0

    if args.seed_state:
        state = load_state()
        findings = evaluate(sheet, state, people)
        suppress(findings, state, now)
        record_restarts(sheet, state)
        save_state(state)
        print(
            f"seeded {len(findings)} open finding(s) into {STATE_PATH}; "
            "none were posted. They will be raised only if they escalate."
        )
        for item in findings:
            print(f"  {item['class']:18} {item['key']}")
        return 0

    state = {"keys": {}, "restarts": {}} if (args.no_state or historical) else load_state()
    findings = evaluate(sheet, state, people)
    if not (args.no_state or historical):
        findings = suppress(findings, state, now)
        record_restarts(sheet, state)
        save_state(state)
    return report(findings, sheet, args, post_ok=args.post and not historical)


def report(findings: list[dict], sheet: dict, args, post_ok: bool) -> int:
    if args.json:
        print(json.dumps(findings, indent=1, sort_keys=True))
    if not findings:
        if post_ok and args.pulse:
            post(
                f"Clean tick on `{sheet['body']}` at {sheet['nowIso']} — "
                f"{len(sheet['seats'])} seats, no findings.",
                mention=False,
            )
        if not args.json:
            print(f"clean: {len(sheet['seats'])} seats, no findings at {sheet['nowIso']}")
        return 0

    if post_ok and rock_is_mid_turn(sheet):
        print("watchdog: rock has a turn in flight in the health channel; skipping this tick")
        return 10

    text = render(findings, sheet)
    wake = any(f["severity"] == "wake" for f in findings)
    if post_ok:
        result = post(text, mention=wake)
        print(json.dumps(result) if result else "watchdog: post failed")
    elif not args.json:
        print(text)
    return 10


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

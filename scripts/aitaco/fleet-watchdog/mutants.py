#!/usr/bin/env python3
"""Prove the watchdog's tests can fail.

A suite that has never seen the fault it guards is a clean sheet, not evidence.
This breaks one thing at a time and requires the suite to go red for each, then
restores the tree and requires it to go green again.

Two of these are the collection bugs that shipped in the first draft. Both
survived the entire fixture suite when they were re-introduced, because the
fixtures are already-collected sheets and the bugs live in collect(); that is
what put the collect() and ordering tests in test_watchdog.py.

COMMIT FIRST. This rewrites watchdog.py in place and restores it from a string
held in memory — a crash between the two loses whatever was uncommitted.

Run: python3 mutants.py
"""

import subprocess, pathlib, sys
p = pathlib.Path('watchdog.py')
orig = p.read_text()

MUTANTS = [
 ("limit: ignore status, treat every report as quiet",
  '''if report.get("status").and_then''', None,
  ('    if status == "rejected" and resets:', '    if False and resets:')),
 ("limit: the original bug — sort turn files by name, not mtime",
  None, None,
  ('paths.sort(key=lambda p: p.stat().st_mtime if p.exists() else 0, reverse=True)',
   'paths.sort(reverse=True)')),
 ("limit: the original bug — only inspect the last record of a file",
  None, None,
  ('    for rec in reversed(tail_jsonl(path)):',
   '    for rec in reversed(tail_jsonl(path))[:1]:')),
 ("orphan: never consider a turn silent",
  None, None,
  ('ORPHAN_SECS = _secs("WATCHDOG_ORPHAN_SECS", 300)',
   'ORPHAN_SECS = _secs("WATCHDOG_ORPHAN_SECS", 99999999)')),
 ("stranded: the false positive — anchor on turn end, not turn start",
  None, None,
  ('                since = turn.get("startedAt") or turn["completedAt"]',
   '                since = turn["completedAt"] - 5')),
 ("veto: a held seat reported as safe to restart",
  None, None,
  ('    return bool((data.get("unit") or {}).get("hasLimitHold"))',
   '    return False')),
 ("limit: unknown harness silently counted as dead-lettered",
  None, None,
  ('(held if has_hold is True else killed if has_hold is False else unknown).append(row)',
   '(held if has_hold is True else killed).append(row)')),
 ("dropped: never mind a missing p tag",
  None, None,
  ('                if pub not in ptags:', '                if False:')),
 ("dropped: a p tag that never became a turn is fine",
  None, None,
  ('                if not seen and not ran:', '                if False:')),
 ("offline: a sleeping body with work waiting is fine",
  None, None,
  ('        if not stale or (seen and now - seen < BODY_OFFLINE_SECS):',
   '        if True:')),
 ("offline: wake on any sleeping body, work waiting or not",
  None, None,
  ('        if not waiting:\n            continue', '        if False:\n            continue')),
 ("suppress: re-raise every finding on every tick",
  None, None,
  ('        prior = keys.get(item["key"])', '        prior = None')),
 ("wake-dead: trust the relay's `accepted` and never check delivery",
  None, None,
  ('            if wake_landed(data, post["id"]):\n                continue',
   '            if True:\n                continue')),
 ("wake-dead: the original bug — derive channels from seat activity alone, "
  "so a channel with no turns in it is invisible",
  None, None,
  ('    channels.add(HEALTH_CHANNEL)', '    pass')),
 ("wake-dead: judge a post the instant it is made, before a mid-turn seat "
  "could have got to it",
  None, None,
  ('WAKE_DEAD_SECS = _secs("WATCHDOG_WAKE_DEAD_SECS", 1200)',
   'WAKE_DEAD_SECS = _secs("WATCHDOG_WAKE_DEAD_SECS", 0)')),
 ("wake-dead: a queued decision counted as a loss",
  None, None,
  ('        if row.get("eventId") == event_id and row.get("decision") == "queued":\n'
   '            return True',
   '        if False:\n            return True')),
 ("wake-dead: report the silence without its cause",
  None, None,
  ('            return WAKE_LOST_DECISIONS.get(', '            return {}.get(')),
 ("preflight: run half-blind when the CLI is missing, the way the unit did "
  "before it carried its own PATH",
  None, None,
  ('    if (args.relay or args.post) and not args.check and buzz_on_path() is None:',
   '    if False:')),
 ("state: commit the suppression ladder whether or not anything was delivered "
  "— the bug that ate the first real WAKE_DEAD",
  None, None,
  ('    if keeps_state and delivered:', '    if keeps_state:')),
 ("escalation: a wake-dead naming the escalation seat itself is not special, "
  "so the alarm is mentioned down the path it is reporting as broken",
  None, None,
  ('        if f.get("ownerEscalation") or f["evidence"].get("seat") == ESCALATE_NAME:',
   '        if f.get("ownerEscalation"):')),
 ("escalation: never re-raise a wake-dead nothing answered",
  None, None,
  ('            and now - (prior.get("posted") or now) >= WAKE_DEAD_ESCALATE_SECS',
   '            and False')),
 ("escalation: decide to wake the owner and then mention the seat anyway",
  None, None,
  ('            target = OWNER_PUBKEY', '            target = ESCALATE_PUBKEY')),
]

fails = 0
for name, _a, _b, (find, repl) in MUTANTS:
    if find not in orig:
        print(f"SKIP  {name} — anchor not found"); fails += 1; continue
    p.write_text(orig.replace(find, repl, 1))
    r = subprocess.run([sys.executable, 'test_watchdog.py'], capture_output=True, text=True)
    red = [l for l in r.stdout.splitlines() if l.startswith('FAIL')]
    ok = r.returncode != 0
    print(f"{'CAUGHT' if ok else 'MISSED':7} {name}")
    for l in red[:3]:
        print(f"          {l}")
    if not ok:
        fails += 1
    p.write_text(orig)

r = subprocess.run([sys.executable, 'test_watchdog.py'], capture_output=True, text=True)
print(f"\nrestored tree: {'green' if r.returncode == 0 else 'RED — tree not restored!'}")
sys.exit(1 if fails or r.returncode else 0)

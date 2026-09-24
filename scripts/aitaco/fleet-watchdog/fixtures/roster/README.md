# Frozen roster for the tests

`watchdog.py` resolves seat names to bodies and pubkeys from two files that
live outside this repository: `~/dev/agents/deploy/seats.conf` (aitaco-llc/agents)
and `~/.config/buzz-agents/pubkeys.txt` (written by `bootstrap-keys.sh`). Neither
exists on a CI runner, and without them every relay-backed class in the suite —
STRANDED_HANDOFF, DROPPED_TRIGGER, BODY_OFFLINE, WAKE_DEAD — silently finds no
seats and the tests that assert a finding go red.

These are copies, taken 2026-09-23, so the suite runs anywhere.

Freezing them is right rather than merely convenient: every sheet in
`fixtures/` is an instant captured in the past, and the roster that gives those
sheets meaning is the roster as it was then. A test that changes its verdict
because somebody edited their own machine's config is not a test.

They hold names, bodies and **public** keys. Nothing here is a secret.

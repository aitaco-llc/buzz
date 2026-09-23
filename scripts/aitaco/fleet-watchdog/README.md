# fleet-watchdog

Deterministic stall detection for the aitaco agent fleet. Runs on a timer,
reads the turn logs `buzz-acp` already writes, and posts one message into
#fleet-health when it finds something. It never calls a model.

## Why a script and not an agent

Every seat is a `buzz-acp` process that is purely reactive: it runs only when a
relay subscription hands it a trigger. Nothing in that design notices when a
turn dies, when a handoff is never returned, or when the provider refuses the
whole account. Those stalls are silent and the fleet sits idle.

`buzz-acp` has a native heartbeat (`BUZZ_ACP_HEARTBEAT_INTERVAL`). It is the
wrong primitive for this, for a reason in the code rather than in taste. At
`5b54d91af`, `crates/buzz-acp/src/pool.rs:2175` — "A heartbeat passes base
only: it has no channel, so there is no core or canvas to carry, and it has
never been given the persona" — and `:2464` returns no core memory for
`PromptSource::Heartbeat`. A heartbeat turn is the chief of staff without the
chief of staff: no persona, no memory, no thread, and one session that grows by
144 turns a day. It also fires only when the pool is idle, which is when there
is least to check.

The cost that argues against an LLM here is not tokens. It is that a model can
misread a log and emit a mention, and every mention is a full Claude-seat turn
somebody pays for. A script cannot misread the index.

## Shape

    collect()   reads the world and returns a SHEET — raw evidence, no verdicts
    evaluate()  is a pure function of (sheet, state, now) -> findings
    render()    turns findings into the message

`evaluate` never touches the disk. That is what makes a sheet captured today
re-judgeable by a later version of the script, and it is the only reason the
tests below can exist without a fleet to break.

## Classes

| Class | Signature | Source |
|---|---|---|
| `LIMIT` | newest `_claude/rateLimit` report has `status: rejected` | turn logs |
| `LIMIT_DEADLETTER` | refused seats whose harness predates buzz#58 | turn logs + `/proc` |
| `LIMIT_WARNING` | `status: allowed_warning` at or above 80% utilization | turn logs |
| `ORPHAN` | open turn, no `turn_liveness` tick for 5 min | turn logs |
| `STALLED_TURN` | open turn, liveness ticking, no `acp_read` for 20 min | turn logs |
| `UNIT_DOWN` / `UNIT_FLAPPING` | unit inactive, or 3+ restarts in an hour | systemd |
| `STRANDED_HANDOFF` | B answered A's p-tag `ok`, has no turn open, published nothing | logs + relay |
| `DROPPED_TRIGGER` | `@name` with no `p` tag, or a `p` tag that never became a turn | logs + relay |
| `BODY_OFFLINE` | remote seat offline 30 min with an unanswered mention | relay presence |

### Two things about `LIMIT` that are easy to get wrong

**The report's presence means nothing.** 1165 turn files on hip carry a
`_claude/rateLimit` object, because the provider re-sends it on every turn once
a window starts filling. `status` is the discriminator: `allowed` is quiet,
`allowed_warning` is a filling window, `rejected` is the limit in force.

**"Refused" is three groups, not two.** A seat whose harness carries
[buzz#58](https://github.com/aitaco-llc/buzz/pull/58) *held* its triggers —
they resume by themselves and re-kicking them doubles the work. A seat whose
harness predates it spent its retry budget and dead-lettered: that work is gone
and only a re-kick brings it back. A seat whose binary could not be probed is
*unknown*, and is reported as unknown rather than guessed. Which harness a seat
runs is asked of the process itself (`strings /proc/<pid>/exe`), not of
`~/.local/bin`: installing a binary does not change a running seat.

### The restart veto

`EventQueue` has no `Serialize` and nothing writes it to disk. A seat held on a
usage limit is holding every one of those triggers in memory and nowhere else,
so restarting it destroys exactly the work buzz#58 preserved. Findings about a
held seat carry `restartSafe: false` and say so in the message, rather than
leaving it to be remembered.

## Modes

    watchdog.py --dry-run            collect, evaluate, print (posts and writes nothing)
    watchdog.py --post --relay       the timer's mode
    watchdog.py --seed-state         record what is wrong now without posting
    watchdog.py --capture FILE       save a sheet, judge nothing
    watchdog.py --check FILE         judge a saved sheet offline
    watchdog.py --at ISO8601         reconstruct the sheet as of a past instant

Exit codes: 0 clean, 10 findings raised, 1 bad input. The systemd unit sets
`SuccessExitStatus=10`, or every tick that found something would be logged as a
failed unit and the watchdog would become the noisiest thing in the journal.

`--post` stays quiet for the first five minutes after boot
(`--min-uptime`). A reboot orphans every in-flight turn by definition, so the
first tick after one would report the reboot to a chief of staff whose own seat
has not finished starting — and a mention that lands before a seat is listening
is lost, because `buzz-acp` replays only the five seconds before its process
start. That grace is in the script rather than in the timer on purpose: a
timer's `OnBootSec` silently schedules nothing when the timer is enabled after
it has already elapsed, and `systemctl list-timers` then prints `NEXT` as `-`
while the watchdog never runs. Which is the exact failure it exists to catch.

`--at` is the one worth knowing about. Turn logs are timestamped, so the sheet
for any past instant is reconstructible, and a detector can be shown firing on
the real bytes of a real incident instead of on a mutant.

## Tests

    python3 test_watchdog.py

Both fixtures are real captures, not fabrications:

- `sheet-2026-09-22T0052Z-limit-outage.json` — two minutes after the five-hour
  window reset on 2026-09-22, with 67 refused triggers across four seats behind
  it. **The first draft of the detector found nothing in it.** Turn files are
  named by UUID, so sorting them by name is not sorting them by time; and the
  rate-limit report sits a few records before the end of a failed turn rather
  than on its last line. That fixture exists to keep both bugs out.
- `sheet-2026-09-22T0030Z-limit-in-force.json` — the same outage while the
  provider was still refusing. The pair is what proves the restart veto is a
  real check: on at 00:30Z, off at 00:52Z.
- `sheet-live-clean.json`, `sheet-live-relay.json` — a healthy fleet. A
  detector that fires on everything is as useless as one that fires on nothing,
  and only a clean sheet catches that. The relay fixture is sanitised: every
  message keeps its id, pubkey, timestamp and tags, and its prose is reduced to
  the `@`-tokens the dropped-trigger detector actually reads.

`DROPPED_TRIGGER` and `BODY_OFFLINE` only fire on a fleet that is already
broken, so no healthy capture contains either. Untested they would be two
detectors nobody had ever seen work, which is the same as not having them —
each case is made by editing the real sheet in the one way that produces the
fault: strip a `p` tag from a real mention, delete a real trigger from the
seat's decision log, put a Mac to sleep with a mention waiting. `BODY_OFFLINE`
carries its negative too: offline with nothing waiting is somebody's evening,
not an incident.

The relay fixture also carries the one false positive found in testing.
`STRANDED_HANDOFF` fired on a seat that had in fact answered, because a seat
publishes in the MIDDLE of its turn while its index row is written after it
returns — the reply landed at 15:22:35 and the turn closed at 15:22:44.9. The
test deletes that reply from the same bytes and requires the detector to fire,
so the fix cannot be "widen the grace until it goes quiet".

    python3 ci-sim.py

runs the same suite in a runner-shaped environment: no fleet `buzz` on `PATH`,
and a machine booted thirty seconds ago. Both are ambient facts about hip that
a test can read by accident instead of reading the code — `main()`'s preflight
refuses a `--post` run without the CLI, and its `--min-uptime` grace returns
before anything is written. One pull request cost two red pushes to those two,
neither visible from a passing local run. A test that reaches `main()` stubs
`buzz_on_path` and passes `--min-uptime 0`; `ci-sim.py` is how you find out
beforehand that it did not.

### Proving the tests can fail

    python3 mutants.py

Breaks one thing at a time and requires the suite to go red for each: twelve
mutants, including both collection bugs from the first draft. A suite that has
never seen the fault it guards is a clean sheet, not evidence.

Two of those mutants survived the whole fixture suite when they were first
re-introduced, which is why `test_watchdog.py` also tests `collect()` directly
and carries one constructed ordering case: on hip's real logs the UUID-highest
turn file happens also to be the newest, so real bytes cannot exercise the
ordering at all.

## Install (hip)

    install -Dm755 watchdog.py ~/.local/libexec/fleet-watchdog/watchdog.py
    install -Dm644 fleet-watchdog.service ~/.config/systemd/user/
    install -Dm644 fleet-watchdog.timer   ~/.config/systemd/user/

The unit carries its own `Environment=PATH=` with `~/.local/bin` first. The
systemd user manager's PATH does not have it, every relay read here is a bare
`buzz`, and `buzz_json` swallows the OSError a missing binary raises — so
without that line the watchdog read an empty relay and printed `clean: N seats,
no findings`. A preflight in `main()` now refuses a `--relay` or `--post` run
with no `buzz` on PATH; exit 1 is not `SuccessExitStatus=10`, so systemd marks
the unit failed and the journal says why. macOS is unaffected: the plist runs
`bash -lc`, which reads the profile.
    ~/.local/libexec/fleet-watchdog/watchdog.py --seed-state   # do not skip
    systemctl --user daemon-reload
    systemctl --user enable --now fleet-watchdog.timer

`--seed-state` is not optional. A cold start has no state file, so every
settled incident still on disk reads as new and rock is woken with a week of
history. Seeding records them as seen without posting; they are raised only if
they escalate.

Not `~/.local/bin`: writing there is the fleet deploy path and this is not a
fleet binary. `libexec` keeps a watchdog update from being mistaken for a
harness rollout.

## Install (metal)

    install -Dm755 watchdog.py ~/.local/libexec/fleet-watchdog/watchdog.py
    cp co.aitaco.fleet-watchdog.plist ~/Library/LaunchAgents/
    ~/.local/libexec/fleet-watchdog/watchdog.py --seed-state --body metal
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.aitaco.fleet-watchdog.plist

Each body watches itself and posts into the same channel, because `~/.buzz` is
per-body: a path written on hip cannot be opened from the Mac. A sleeping Mac
has a sleeping watchdog, and that gap is covered from hip, whose `BODY_OFFLINE`
class reads relay presence.

### Who a finding is mentioned to

Three rungs, and the message says which one it is on.

1. **rock** for an ordinary wake. It sets priority and owns restarts.
2. **aldrin** for a `WAKE_DEAD`, never the seat the finding is about — that
   mention travels the exact path being reported as broken. aldrin owns
   `crates/buzz-acp` and `deploy/fill-allowlists.sh`, the two places a wake
   edge is ever repaired.
3. **the owner** when there is no seat left to tell. Two conditions, either
   sufficient: a `WAKE_DEAD` names the escalation seat *itself* — a second
   fallback seat would not help, because every allowlist comes from the same
   generator — or one has been standing, posted and unanswered, for two ticks.
   The message states the decision being asked for, because an allowlist change
   only takes effect on a seat's next start and nothing automated will do it.

A DM leg (`WATCHDOG_OWNER_DM_CHANNEL`) still exists and still fires alongside
rung 3 when configured. It is not required: rung 3 posts in `#fleet-health`,
where the owner is a member, and a mention there notifies. The script will not
open a DM conversation itself — that is outward-facing, and a timer should not
start a conversation in someone's client.

## Identity

The watchdog posts as its own key, minted on hip 2026-09-22, secret at
`~/.config/aitaco/fleet-watchdog.env` (0600). No model is behind it. It is
deliberately not in `~/.config/buzz-agents/`, because it is not a seat and must
never acquire a `buzz-acp` unit.

It mentions the chief of staff and nobody else. It never mentions the seat a
finding is about: a seat that cannot run cannot read a mention either.

## Blast radius

Five rules, all in `suppress()` and `report()`:

1. At most one message per tick.
2. Each incident key is raised once, and again only when its severity climbs
   from notice to wake — the only change that asks for a different action. One
   exception: a `WAKE_DEAD` still standing two ticks after it was posted is
   raised a second time, and only a second time.
3. A limit still in force is a notice, not a wake. There is nothing to do until
   the window resets, because a re-kick cannot run either. The wake fires at
   `resetsAt + 60s` with the list of what was actually lost.
4. A tick is skipped entirely if rock already has a turn in flight in the
   health channel.
5. Keys unseen for a day are dropped, so a closed incident cannot be re-raised
   by a later tick.
6. The state file is written only by a run that delivered what it found. Rule 2
   retires a key the moment `suppress()` hands it back, so the write is the act
   of retiring the incident — and a `--dry-run`, a post the relay refused, or a
   tick skipped by rule 4 has retired something nobody read. On
   2026-09-23T21:07:28Z a `--relay` inspection recorded the first real
   `WAKE_DEAD` as posted and the timer three minutes later published `clean`.
   `report()` returns whether it delivered; `main()` commits on that alone.

## Thresholds

Every one is a starting value rather than a measurement, and every one is
overridable from the environment (`WATCHDOG_ORPHAN_SECS`, `WATCHDOG_STALL_SECS`,
`WATCHDOG_WINDOW_SECS`, …). Tune them from the first week of #fleet-health
rather than from this file.

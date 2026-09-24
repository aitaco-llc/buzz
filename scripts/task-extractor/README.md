# The task extractor: what the audit set actually is, and what that changes

Design note for `PLANS/BUZZ_TASK_TRACKER_ARCHITECTURE_2026-09-23.md` §5, and the
eval that gates it. Written by aldrin, 2026-09-23, at `7bed33ef6`. The nest copy
(`~/.buzz/PLANS/TASK_EXTRACTOR_2026-09-23.md`) is the same text; this one is here
because the corpus needs a home both bodies can read.

## Answer

Three things the data changed. Each is a correction to §5, not a quibble.

1. **An utterance produces 0..N tasks, not 0..1.** §5's output schema is a single
   object. The two utterances in this window that caused the most dropped work
   are both multi-task, and one of them lost work *inside* itself — the audit's
   own line for `6bfd1e01` reads "audio was never dispatched to Nathaniel; iOS
   hardware validation was never dispatched to Woody", which is two sub-items a
   one-task extraction swallows by construction.
2. **The eval set cannot be assembled by one seat.** Of the audit's 87
   utterances, **11** are readable from this seat. The rest are in
   `#user-support` (not a member), DMs (not a party) and huddles (not in the
   room). The same fact that makes the harness the right home for the extractor
   makes the eval per-seat: only rock's process can replay rock's DMs.
3. **The routing rule has one branch in practice.** §5 routes extraction to the
   first seat in the message's `p` tags, falling back to rock. **Zero of the 11
   carry a `p` tag** — Lloyd addresses people in prose ("Rock, please check in
   with all agents…") and posts top-level. So rock's harness is the extractor
   for all channel traffic, which is a single point of failure on exactly the
   seat the audit shows dying on budget exhaustion. The design survives that
   only because extraction runs *before* the model turn; that is now the
   load-bearing reason for it rather than a convenience.

## 1. What the "87-utterance audit set" is

It is not a labelled set. `RESEARCH/AUDIT_UTTERANCES_FLASH_MIGRATION_2026-09-23.md`
is a narrative inventory: it names utterance *numbers* in groups ("Utterances 22,
23, 31, 48, 73, 78-81"), gives event ids for 11 of them, and labels outcomes
(`COMPLETED` / `DROPPED` / `STALLED`) rather than extractions
(`create` / `attach` / `none`). Outcome and extraction are different questions —
a COMPLETED item still needed a task.

So the set has to be rebuilt from the relay before it can score anything.

### What this seat can see

Queried across every channel this seat is a member of, over the audit's own
window (`2026-09-21T22:30Z .. 2026-09-23T01:35Z`; no query was truncated —
each channel's returned range spans the whole window):

| channel | messages | Lloyd |
|---|---|---|
| ml-platform | 108 | 3 |
| game-platform | 63 | 0 |
| buzz-platform | 54 | 1 |
| game-dev | 38 | 1 |
| general | 22 | 6 |
| fleet-health | 6 | 0 |
| studio | 3 | 0 |
| **total** | **294** | **11** |

`#user-support` (`3d7b6127`) does not appear in `buzz channels list` for this
seat, so bug reports #7 and #8 — the audit's first dropped item — are not
readable here at all.

### The seed corpus

`scripts/task-extractor/corpus.json` holds all 11 with hand-assigned labels
and the reason for each, citing the audit's outcome where the two overlap.
It comes out balanced by accident, which is the right shape for a first gate:

- **create ×4** (12 tasks total across them)
- **attach ×3**
- **none ×4**

## 2. What the corpus says about the design

### 2.1 One message, many tasks — and an ordering

`9aee0484`, the first utterance in the window:

> "I think we need to move you rock to gemini, get rid of rock 2, evict the old
> memories of details about completed work and then once all of that is done we
> should investigate spark 1.3"

Four asks, and the fourth is explicitly ordered after the first three. That is a
`create` of 4 with one `blocked-by` link — the §3.4 primitive, needed by the
very first message of the audit window. `buzz issues link --kind blocked-by`
(buzz#73) already writes it.

### 2.2 The `none` class is a third of the set, and it is the dangerous one

Four of eleven are status queries or process instructions:

- `5d472ef8` "where are we at in all our initiatives?"
- `648e67e3` "check in with all responsible engineers … and push us forward"
- `a04fd4d9` "are you sure everyone is actually working and not stuck?"
- `63e0c989` "check in with all agents and ask them if they are blocked"

An extractor that creates for these produces tasks whose done-when is
unwritable, and it produces them *repeatedly* — `63e0c989` is a near-duplicate
of `648e67e3` nineteen hours later. A board flooded with "where are we at" is
worse than no board, because the real items sink below it.

The hard judgement in this set is that `5872666e` — "you should be waking every
10 minutes and checking on team progress … work with wren to architecture a
robust solution" — sits in the same conversation, in the same frustrated voice,
and **is** a create: the watchdog, which shipped. All four of the others are
about the same frustration and ask for no thing to exist. Any extractor that
cannot separate these four from that one is not ready.

### 2.3 `attach` is sometimes stated outright

`2279229f`: "I know we already are running a comparison. Can we just add in
Luna to that?" An extractor that creates here has ignored an explicit
instruction in the text. This is the cheapest case to get right and the most
embarrassing to get wrong.

## 3. The contract, revised

```jsonc
// input
{
  "message":      { "id", "channel", "author", "text", "threadRoot" },
  "threadContext": [ /* the thread root's text and the last N replies */ ],
  "board":        [ { "id", "subject", "state", "assignee" } ],  // open tasks, capped
  "project":      { "repoOwner", "repoId" }
}

// output — a LIST, and it may be empty
{
  "tasks": [
    { "action": "create",
      "subject":   "…",           // <= 256 chars, the NIP-34 subject tag
      "why":       "…",           // one line, or "not stated"
      "doneWhen":  "…",           // the observable result
      "assignee":  "<hex>|null",
      "blockedBy": 0 },           // index into this list, or null
    { "action": "attach",
      "attachTo": "<issue-id>",   // MUST be an id from `board`
      "note":     "…" }
  ]
}
```

Changes from §5: `tasks` is a list; `blockedBy` carries the ordering `9aee0484`
needs; `attachTo` is constrained to the board that was supplied, so a
hallucinated id fails validation instead of creating a dangling link.

**Idempotency.** §3.1 makes the `source` tag the dedup key. With N tasks per
message that key no longer identifies a task, so the check moves up a level:
before extracting, ask the relay whether *any* task already cites this source;
if one does, skip the message entirely. Extraction per message is atomic — all
N or none — so a replay adds nothing.

**Validation before publication, not after.** Every field is checked by the
harness against things it can verify: `attachTo` ∈ board, `assignee` is a
64-hex pubkey of a known seat, `subject` non-empty and within the tag limit,
`blockedBy` a valid index. A task that fails validation is dropped and logged,
never published half-formed. This is the same posture as the NIP-AR receipt:
a record that names the wrong thing is worse than none.

## 4. Where it runs, and what it costs

Unchanged from §5 and now with a reason behind it: in `buzz-acp`, at trigger
receipt, **before** the seat's model turn is queued. The routing finding in §0.3
is why — rock is the extractor for all channel traffic, and rock is the seat
that dies on budget exhaustion, so extraction must not be downstream of rock's
turn surviving.

Gated by `BUZZ_ACP_TASK_EXTRACT_AUTHORS=<lloyd hex>`, absent by default. The
model is Rebrand (`rebrand-acp`), never the seat's Claude subscription, so a
Claude limit hold cannot block capture.

**Cost.** `gemini-3.8-flash` is $0.75/Mtok in, $3.75/Mtok out
(rebrand `crates/of/src/pricing.rs:31-39`). A call carrying the message, its
thread root and a capped board is on the order of 4k in / 300 out ≈ **$0.004**.
At the audit's own rate — 87 utterances in 27 hours — that is about **$0.35 a
day**, and it is manifest-estimated, so it must not be added to any
wire-reported column (NIP-AM §Numeric validity).

**Latency.** The extractor sits in front of the turn, so its latency is added to
every matching message's time-to-first-response. Budget it hard: one call, a
short timeout, and on timeout or error the turn proceeds with no extraction and
a warn line. Capture is important; blocking a reply on it is not.

## 5. The gate

`scripts/task-extractor/task-extractor-eval.py` replays a corpus and scores it. The rule wren
set, and it is the right one: **no false `none` on any item the audit recorded
as dropped.** A missed task is the failure mode this whole project exists to
remove; a spurious one is visible on the board and can be closed.

Reported per run: confusion over `create`/`attach`/`none`, plus task-count error
on the `create` rows, because 2.1 makes count a first-class failure. An
extractor that calls `6bfd1e01` a create and returns one task has got the label
right and the work wrong.

**The check must be able to fail.** The corpus ships with the labels and the
reasoning, so a scorer that returns everything green can be disproved by hand
against `scripts/task-extractor/corpus.json`; and a stub extractor that
answers `none` to everything must score 4/11 and fail the gate on four items,
which is the control run to record before any model is wired in.

## 6. What is needed, from whom

- **rock** — the other 76. Its seat is the only one that can replay its own DMs
  and `#user-support`, and it wrote the audit, so it owns the labels there.
  Same schema as `corpus.json`. Until those exist the gate is scored on 11
  utterances and says so.
- **wren** — §5's schema is singular; §2.1 says it cannot be. And §6's board
  states are already with it (the `44200`-is-owner-encrypted problem, raised in
  `#buzz-platform` c887d5dd).
- **Lloyd** — nothing. This costs about a dollar a week and adds a few hundred
  milliseconds to a reply; neither needs a decision.

## 7. Receipts

- Corpus and raw pulls: `.scratch/aldrin/extractor/` (`corpus.json`,
  `lloyd-utterances.json`, one JSON per channel).
- Window and per-channel counts: section 1, reproduced by
  `buzz messages get --channel <uuid> --since 1790029800 --limit 500`.
  Note the trap: `buzz --format compact` omits `pubkey`, so an author filter on
  compact output returns zero and reads exactly like "Lloyd said nothing".
- `p`-tag finding: every one of the 11 has `p=NONE`; five are threaded replies,
  six top-level.

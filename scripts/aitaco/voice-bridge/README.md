# Voice bridge: a seat's voice in a huddle

`crates/buzz-voice-bridge` joins a Buzz huddle's audio room as a seat and holds
the conversation through Gemini Live. The seat (Claude) keeps the authority.
Gemini talks **as the seat**, in the first person, and it has exactly one tool,
`work`, which hands a request to the seat. The design, and rock's conditions
for it, are in the `#buzz-platform` thread `54da67d0` and
`~/.buzz/PLANS/BUZZ_VOICE_AND_REBRAND.md` on hip. One bridge process is one
seat's voice; run one per seat to huddle with any agent.

```text
phone or Desktop ──huddle──▶ relay audio room ◀──Opus 20 ms──▶ bridge ◀──PCM──▶ Gemini Live
                                                                 │
             work: kind:9 in the parent, ["voice-bridge","ask"], p = seat
                                                                 ▼
                         the seat (buzz-acp --self-wake-tag voice-bridge=ask)
                                                                 │
             reply in that thread ──▶ bridge ──▶ Gemini: "Your work came back …"
                                                                 │
             call end ──▶ transcript + wake in the parent ──▶ the seat records the work
```

- **One identity.** The persona is first person: "You are {agent}, on a live
  voice call with {human}." The voice never says "I'll check with rock"; it says
  "one sec, let me check" and calls `work`. The tool is `NON_BLOCKING`, and the
  bridge answers it at once (`status: started`, `scheduling: SILENT`), so the
  aside is never held behind the relay round trip. Answers, progress lines and
  failures then arrive as user turns, which survive a Gemini reconnect.
- **Names come from the relay.** `VOICE_BRIDGE_AGENT_NAME` and
  `VOICE_BRIDGE_HUMAN_LABEL` override; unset, the seat's and the first
  starter's kind:0 profile names are used, with plain fallbacks. The voice's
  transcript label is `<agent> (voice)`.
- **Context on both sides.** At call start the bridge fetches the parent
  channel's recent messages (`VOICE_BRIDGE_HISTORY_LIMIT`, default 40, over
  `VOICE_BRIDGE_HISTORY_DAYS`, default 14) in parallel with the room join and
  puts them in Gemini's system instruction as the voice's own memory of the
  channel. Every ask carries the last `VOICE_BRIDGE_ASK_CONTEXT_LINES` (12)
  transcript lines, so the seat knows what the question is about.
- **Replies are matched by thread.** A reply is matched to its ask by the
  `reply`-marked `e` tag (then any), whatever order the seat answers in. The
  ask tells the seat it may reply once with what it is doing and again with
  the result: every reply in the thread is spoken, the first ends the ask's
  timeout, and while the seat keeps typing after it the wait, the working
  sound and the progress line carry on until it goes quiet. A late reply to
  a timed-out ask is spoken as its answer, never as the next ask's.

- **Trigger.** The caller's kind:48100 in a configured parent channel. The
  relay adds a parent-channel member to the huddle's private channel when it
  joins the audio (`crates/buzz-relay/src/audio/handler.rs`, auto-add path), so
  the call works from any client, the phone included.
- **Identity.** The bridge signs with the seat's key, read from the seat's own
  env file. Every event it signs carries `["voice-bridge", "ask"|"transcript"]`.
  Only `ask` wakes the seat, and only a seat that opted in with
  `BUZZ_ACP_SELF_WAKE_TAG=voice-bridge=ask`.
- **Transcript.** Each utterance is posted to the huddle channel, labelled by
  speaker. At the end of the call one message goes to the parent: a line saying
  how the call ended, how long it ran, who was in it, the ask and error tallies
  and the path of its log, with the transcript under it. It is posted whether
  the call ended cleanly or failed, retried three times if the relay refuses
  it, and posted on the next start from the call log if the bridge died first
  (`recovery.rs`; only logs this seat's key wrote, so seats sharing a log
  directory never post for each other).
- **Recorded as work.** When anything was said, that call-end post is tagged
  `t=huddle-transcript`, signed `["voice-bridge","ask"]` and addressed to the
  seat, so it wakes the seat. The post tells the seat to record every action
  item, commitment and decision (`buzz issues create`, `buzz mem set`, a
  hand-off to a teammate) and to reply in the thread with a written recap.
  A call nobody spoke in posts the stats line only and wakes nobody.
- **Session length.** Gemini's session resumption and sliding-window
  compression are on. On `goAway` or a dropped socket, the bridge reconnects
  with the latest handle.

## What a post-mortem has to work with

Everything is in `~/.local/state/buzz-voice-bridge/` (`VOICE_BRIDGE_LOG_DIR`).
**No audio is ever written**, in any mode; the audio is counted, not kept.

- `bridge.jsonl` — the watcher, across every call and every restart: `up` with
  the build sha, pid and resolved config, `identity`, each relay connection and
  subscription, a `heartbeat` that proves the *subscription* answers rather than
  that the socket is merely open, every `huddle_seen`, every `skipped` one with
  its reason, `call_spawned` / `call_ended`, `start_failed` when the process
  cannot come up at all, and `down`. Rotated at 8 MiB, one previous file kept.
- `<time>-<huddle>.jsonl` — one call: `call_start` (build sha, pid, config,
  names), `room_joined` with `join_ms`, `history` with what the voice was
  given, `gemini_connected` with `connect_ms`, transcript lines, `work` and
  `ask_posted`, `seat_answer` with `waited_ms`, `audio_stats` every 5 s and
  once at the end, `response_latency` per answer, `gemini_usage`, exactly one
  ending — `call_end` with a reason or `call_failed` with the error chain and
  the stage it failed in — and `outcome_posted` once the parent has the
  transcript. Kept 30 days (`VOICE_BRIDGE_RETENTION_DAYS`), because these hold
  every word spoken.
- `<time>-<huddle>.frames.jsonl` — only with `VOICE_BRIDGE_TRACE_FRAMES=1`:
  every Gemini server message with each `data` payload replaced by its size.
  A debugging tool, off by default.

`audio_stats` counts each direction separately and each peer index on its own:
Opus frames in, decode errors, PCM samples handed to Gemini, Gemini audio frames
and samples, Opus frames out, DTX frames and silence injections. Counts are
cumulative since `call_start`, so two records give a rate and the last gives the
totals. `response_latency` measures from the human's last audio frame to the
first Gemini audio frame, and again to the first Opus frame into the room —
Gemini's `turnComplete` is the *model's* turn ending, not the human's, so that
is the closest thing to "how long before he heard anything".

`buzz-voice-bridge --version` prints the commit the binary was built from.

## Lab

`lab.sh` runs the whole path on one machine: throwaway keys, a local relay, a
scripted fake Gemini (`fake_gemini.py`), a stub seat (`stub_seat_agent.py`)
under the buzz-acp being tested, and a phone-shaped caller
(`examples/fake_caller.rs`). It touches nothing on `buzz.aitaco.co` and makes
no Gemini call. `lab_check.py` scores the call, the instrumentation and — with
`LAB_FAULT` — the endings.

The crate is its own Cargo workspace, like `desktop/src-tauri`. It links
libopus, a native build that has no place in the relay's Docker image.

```bash
cargo build --manifest-path crates/buzz-voice-bridge/Cargo.toml --bins --examples
LAB_ACP_BIN=<buzz-acp with --self-wake-tag> \
LAB_RELAY_BIN=<buzz-relay> LAB_ADMIN_BIN=<buzz-admin> \
  bash scripts/aitaco/voice-bridge/lab.sh

# and the three ways a call dies, each of which must still write an ending:
LAB_FAULT=room_join ... bash scripts/aitaco/voice-bridge/lab.sh
LAB_FAULT=gemini_connect ...
LAB_FAULT=mid_call ...
```

## Deploy (rock's go only)

1. The rock seat runs a buzz-acp with `--self-wake-tag` (aitaco-llc/buzz#24),
   with `BUZZ_ACP_SELF_WAKE_TAG=voice-bridge=ask` in its env.
2. Secret `gemini-live-api-key` exists in `aitaco-ml-dev`. The bridge reads it
   at start with `gcloud`.
3. Install the binary and `buzz-voice-bridge.service`, then start the unit.

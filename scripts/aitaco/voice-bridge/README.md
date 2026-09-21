# Voice bridge: rock's voice in a huddle

`crates/buzz-voice-bridge` joins a Buzz huddle's audio room as a seat and holds
the conversation through Gemini Live. The seat (Claude) keeps the authority.
Gemini talks, and it has exactly one tool, `ask_rock`, which hands a request to
the seat. The design, and rock's conditions for it, are in the
`#buzz-platform` thread `54da67d0` and `~/.buzz/PLANS/BUZZ_VOICE_AND_REBRAND.md`
on hip.

```text
phone or Desktop ──huddle──▶ relay audio room ◀──Opus 20 ms──▶ bridge ◀──PCM──▶ Gemini Live
                                                                 │
             ask_rock: kind:9 in the parent, ["voice-bridge","ask"], p = seat
                                                                 ▼
                         the seat (buzz-acp --self-wake-tag voice-bridge=ask)
                                                                 │
             reply in that thread ──▶ bridge ──▶ Gemini: "rock answered …"
```

- **Trigger.** The caller's kind:48100 in a configured parent channel. The
  relay adds a parent-channel member to the huddle's private channel when it
  joins the audio (`crates/buzz-relay/src/audio/handler.rs`, auto-add path), so
  the call works from any client, the phone included.
- **Identity.** The bridge signs with the seat's key, read from the seat's own
  env file. Every event it signs carries `["voice-bridge", "ask"|"transcript"]`.
  Only `ask` wakes the seat, and only a seat that opted in with
  `BUZZ_ACP_SELF_WAKE_TAG=voice-bridge=ask`.
- **Transcript.** Each utterance is posted to the huddle channel, labelled by
  speaker. At the end of the call, the whole transcript is posted to the parent.
  A JSONL log of every call goes to `~/.local/state/buzz-voice-bridge/` (no
  audio).
- **Session length.** Gemini's session resumption and sliding-window
  compression are on. On `goAway` or a dropped socket, the bridge reconnects
  with the latest handle.

## Lab

`lab.sh` runs the whole path on one machine: throwaway keys, a local relay, a
scripted fake Gemini (`fake_gemini.py`), a stub seat (`stub_seat_agent.py`)
under the buzz-acp being tested, and a phone-shaped caller
(`examples/fake_caller.rs`). It touches nothing on `buzz.aitaco.co` and makes
no Gemini call. `lab_check.py` scores 13 checks.

The crate is its own Cargo workspace, like `desktop/src-tauri`. It links
libopus, a native build that has no place in the relay's Docker image.

```bash
cargo build --manifest-path crates/buzz-voice-bridge/Cargo.toml --bins --examples
LAB_ACP_BIN=<buzz-acp with --self-wake-tag> \
LAB_RELAY_BIN=<buzz-relay> LAB_ADMIN_BIN=<buzz-admin> \
  bash scripts/aitaco/voice-bridge/lab.sh
```

## Deploy (rock's go only)

1. The rock seat runs a buzz-acp with `--self-wake-tag` (aitaco-llc/buzz#24),
   with `BUZZ_ACP_SELF_WAKE_TAG=voice-bridge=ask` in its env.
2. Secret `gemini-live-api-key` exists in `aitaco-ml-dev`. The bridge reads it
   at start with `gcloud`.
3. Install the binary and `buzz-voice-bridge.service`, then start the unit.

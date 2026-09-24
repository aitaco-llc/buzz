# Rebrand retrieval proof

This proof runs the real Rebrand `of-agent` loop through Buzz's existing ACP
harness, against a real locally served model and an isolated local relay.

```text
mention → buzz-acp → native ACP worker → Rebrand of-agent → rebrand serve
                              │
                              ├─ search_messages → signed, channel-scoped /query
                              ├─ read_thread     → signed, channel-scoped /query
                              └─ validated answer → host-signed threaded /events
```

The model has exactly two read tools. The host publishes the final answer after
checking its schema and citations. Every cited message must come from a completed
`read_thread`, and every identifier in the answer (a word with a digit, four or
more characters) must appear verbatim in a cited message. No `buzz-agent`, developer MCP server, shell
tool, provider selection UI, or model-controlled publication is involved.
Codex and Claude are unaffected and keep their native connections.

## Build and test

Rebrand is private source. The proof builds outside the OSS Cargo workspace.
The build helper resolves the two Rebrand crate manifests against the supplied
checkout, without changing that checkout or downloading from its private registry.
It does not copy or implement Rebrand's loop.

```bash
. ./bin/activate-hermit
export REBRAND_SOURCE=/home/lth/dev/rebrand
export NATIVE_BUILD_DIR=/tmp/buzz-rebrand-native-build
python3 scripts/rebrand-proof/native/build.py build
export PROOF_NATIVE_BIN="$NATIVE_BUILD_DIR/target/debug/buzz-rebrand-proof"
python3 scripts/rebrand-proof/native/build.py test
python3 scripts/rebrand-proof/native/test_protocol.py -v
```

The protocol tests launch that actual binary and Rebrand loop against controlled
HTTP responses. They cover normal ACP execution, cancellation, forged citations,
an invented code behind a real citation,
cross-channel data, a model error carried inside HTTP 200, one recoverable empty
turn, and repeated empty completion. Failed/cancelled
runs must publish nothing. The fake server is only for these failure tests;
it cannot establish real-model quality.

## Run against a real model

Use an available GPU time slot. The script starts only its own processes and
named Docker containers; do not point it at a production relay.

The card is shared. Post a line in #ml-platform before a run. The script refuses
to start (exit 75) when VRAM in use is above the idle baseline,
`PROOF_VRAM_IDLE_MAX_MIB` (default 3500).

```bash
PROOF_NATIVE_BIN="$NATIVE_BUILD_DIR/target/debug/buzz-rebrand-proof" \
PROOF_RELAY_BIN=/home/lth/dev/buzz/target/debug/buzz-relay \
PROOF_ADMIN_BIN=/home/lth/dev/buzz/target/debug/buzz-admin \
REBRAND_BIN=/home/lth/dev/rebrand/target/release/rebrand \
REBRAND_MODEL=/data/rebrand-cdn/llm/qwen2.5-3b-instruct-q4_k_m.gguf \
REBRAND_PORT=18077 \
  bash scripts/rebrand-proof/run.sh
```

`PROOF_BIN_DIR` supplies `buzz` and `buzz-acp` (default `~/.local/bin`). The
proof records their hashes; it does not imply these installed binaries match
this checkout. The native worker is built from source as above. Rebrand engine
version and model path are recorded separately from the loop library source.

The script uses Postgres, Redis and MinIO containers with the prefix
`rebrand-native-proof`; state defaults to `/tmp/rebrand-native-proof`. Override
`PROOF_CONTAINER_PREFIX` and `PROOF_STATE` together for a fresh isolated run.
Ports default to relay 3967, Postgres 55467, Redis 56367, MinIO 59067, health
18067 and metrics 19167. Each has a `PROOF_*_PORT` override. Stop is automatic;
the Postgres and Redis containers and the state are retained for inspection.
MinIO keeps its data in RAM and is recreated each run, because it refuses every
write once its disk is 99% full. Never reuse another task's
prefix or state directory.

## What constitutes a pass

The host seeds a random incident identifier in a heading and a different random
recovery code in a reply. The question contains only the incident identifier.
The recovery reply deliberately does not contain the search identifier, so the
model must search for the heading and read its thread to learn the answer.
The trigger itself is excluded from retrieval results.

All checks must pass:

- The signed reply comes from the test agent and replies to the triggering event.
- Its answer contains the recovery code and a link to the exact resolution event.
- The resolution event was returned by the completed thread reader.
- The real Rebrand loop ran, both read operations occurred, the relay accepted
  publication, and the Buzz harness recorded a successful turn.

`native.json` records model calls, token usage, duration and retrieved sources.
`native.json.event.json` preserves the signed outgoing event before publication.
`seat.log` contains actual tool calls and results. The harness turn log captures
ACP traffic; `results.jsonl` stores the pass/fail verdict. See `RESULTS.md` for
measured runs and the failures that shaped the final proof.

## Through `rebrand-acp` (the packaged Rebrand worker)

The `acp/` host runs the same proof with the loop where it will live in
production: inside Rebrand's own `rebrand-acp` binary (`crates/of-acp`,
aitaco-llc/rebrand#297). Buzz keeps the key, the data and publication.

```text
mention → buzz-acp → acp/host (ACP agent) → rebrand-acp (ACP child) → rebrand serve
                          │
                          └─ HTTP MCP on 127.0.0.1, one bearer token per run:
                             search_messages, read_thread
```

The differences from the native worker are the ones Stage 2's real host will
have to carry:

- **Tools come over HTTP MCP**, not from inside the worker. The host lists them
  afresh on every `tools/list`, so the same narrowing applies: search first,
  then `read_thread` with the found IDs as an `enum`, then nothing. `tools/call`
  refuses a tool that is not on offer.
- **The answer's schema is the session's**, passed as
  `_meta.rebrand.responseFormat` on `session/new`. `of-agent` applies it to a
  turn with no tools on offer, which is why the host withdraws its tools once a
  thread has been read.
- **rebrand-acp holds no key.** It is launched with a cleared environment; it
  refuses to start if it inherits `BUZZ_PRIVATE_KEY` or `BUZZ_AUTH_TAG`.
- **A failed run is a JSON-RPC error**, not a stop reason, and the host
  publishes nothing.

```bash
export CARGO_TARGET_DIR=/tmp/buzz-rebrand-acp-host
cargo build --manifest-path scripts/rebrand-proof/acp/Cargo.toml
PROOF_HOST_BIN="$CARGO_TARGET_DIR/debug/buzz-rebrand-acp-proof" \
PROOF_REBRAND_ACP_BIN=/path/to/rebrand-acp \
  python3 scripts/rebrand-proof/acp/test_protocol.py -v
```

Those protocol tests run the real `rebrand-acp` binary against a scripted model
and relay: the narrowing, the schema on the answering turn (`minItems` and all),
a forged citation, an invented code behind a real citation, an off-schema answer,
an empty citation list from a turn that still had a tool on offer and so carried
no schema, cross-channel data, a model error inside HTTP 200, and cancellation
(which must leave no rebrand-acp process behind). Nothing publishes but the
success case.

The real-model run is `native/run.sh` with two more variables:

```bash
PROOF_NATIVE_BIN="$CARGO_TARGET_DIR/debug/buzz-rebrand-acp-proof" \
PROOF_REBRAND_ACP_BIN=/path/to/rebrand-acp \
PROOF_REBRAND_ACP_ARGS="--max-tokens 8192" \
REBRAND_BIN=/path/to/rebrand REBRAND_MODEL=/data/rebrand-cdn/llm/qwen3-8b-q4_k_m.gguf \
PROOF_MAX_SEQ_LEN=32768 PROOF_TIMEOUT_S=420 \
  bash scripts/rebrand-proof/native/run.sh
```

`grammar_repro.py` is the smallest request that shows the serve-side constraint
failure those runs hit; see `RESULTS.md`.

## Deliberate scope

This is a one-turn, fixed-channel proof worker, not a supported production runtime.
Its host owns the signing key and tools inside one trusted process. It only
accepts the configured fixture question from the ACP prompt. This avoids
mistaking text extracted from a general coding prompt for trusted channel or
reply authority. General request binding, multiple sessions, broker separation,
publication reconciliation after restart, membership-revocation races, model
service resource limits and desktop packaging remain implementation work.

The two tools are exposed progressively using Rebrand's existing `ToolProvider`:
search first, read a retrieved thread next, then produce structured answer text.
This prevents a small model guessing future event IDs or requiring an artificial
completion tool. Host validation accepts normal tool-free completion only after
checking the answer and sources; truncation and exhaustion are failures.

The earlier general-agent PONG proof is preserved in git history at `94906e814`.
It established a different path: Buzz's own loop plus a shell tool. The supported
proof entry point here tests the replacement loop directly.

# Observed results

## Real retrieval: passed

Run `20260919T003828Z-rebrand` (2026-09-19 UTC), with the checked-in
[result.json](result.json). Local raw artifacts are at
`/tmp/buzz-native-strict-proof/runs/20260919T003828Z-rebrand`.

- Rebrand `of-agent` and `of`: source version 0.3.24, checkout `233ff18`.
- Inference executable: `rebrand 0.3.17` (separate, older engine build).
- Model: `qwen2.5-3b-instruct-q4_k_m.gguf`, served as `qwen2`.
- Buzz baseline: `beeb1408f`; installed `buzz`/`buzz-acp` hashes are in raw artifacts.
- Actual Rebrand loop: 3 iterations, **2,038 ms** inside the worker;
  1,502 input tokens, 297 output tokens. This excludes server startup and relay setup.
- Read operations: `search_messages`, then `read_thread`.
- All nine end-to-end checks passed: correct author, random recovery code,
  exact source citation, reply threading, source returned by thread reader,
  actual Rebrand loop, both tools used, relay acceptance, successful ACP turn.

The randomly generated answer existed only in a source reply that did not match
the search identifier. The triggering question was excluded from retrieval.
This establishes a real retrieval path, not an echoed prompt or canned server.
One successful fixture is not a retrieval-quality or reliability benchmark.

## Failure tests: passed

Seven protocol tests drive the actual compiled worker and Rebrand loop against
controlled HTTP responses: success, cancellation, forged citation, cross-channel
response, model error inside HTTP 200, recovery after one empty turn, and repeated
empty completion. Failure and cancellation publish nothing. Three Rust unit tests
also pass. Scoped Clippy with `--no-deps -D warnings`, Rust formatting and shell
syntax checks pass. Repository-wide `just ci` was not run for this standalone
proof; no production workspace package was changed.

## What failed and what was simplified

- A weaker initial fixture passed in 2.6 seconds but allowed search to return
  the answer directly. It was rejected as evidence of thread retrieval. The
  final fixture and pass gate require reading the exact resolution from a thread.
- An identifier embedded in one word did not match a model's shortened FTS query.
  The fixture now uses a separate identifier token.
- Qwen3-4B exhausted the 512-output-token allowance. No answer was published.
  The successful bounded run used Qwen2.5-3B; it does not establish Qwen3 suitability.
- Exposing every operation together encouraged guessed event IDs. Rebrand's
  existing ToolProvider now exposes search, then thread reading, then no tools.
- An extra completion tool produced brittle termination. It was removed;
  final JSON is validated by the host. Empty completions remain failures after
  one recovery using Rebrand's existing RecoverStalled observer. The seven-case
  protocol suite exercises this recovery; the recorded successful real run
  finished in three iterations without needing it.
- Tokio's blocking stdin reader delayed process exit after failures. Explicit
  worker exit now makes cancellation and terminal failures visible promptly.
- A local infrastructure port collision was resolved using isolated ports and
  a fresh state directory. It supplied no inference evidence.

The old stub/general-agent/proxy proof modes and shell-tool persona were removed.
There is one proof entry point, one Rebrand loop, and two read tools. No duplicate
agent loop or provider-selection layer was added to Buzz's production workspace.

## Production work still required

This prototype accepts one configured question in one configured channel.
General ACP request binding, concurrent session lifecycle, production credential
separation, durable publication reconciliation, membership changes, model-service
resource limits, packaging, and broad retrieval evaluation remain unproven.
The signed outgoing event is saved before publication, but there is no automatic
restart reconciliation. Codex and Claude runtime paths are unchanged.

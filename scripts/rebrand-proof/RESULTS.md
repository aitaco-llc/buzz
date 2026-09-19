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

## Through `rebrand-acp`, on qwen3-8b with thinking on: 0 of 10 greedy, 3 of 10 at temperature 0.7

2026-09-19, hip. Rebrand `31fc194` release builds with `--features hip`
(`rebrand` sha256 `a58a0b70…`, `rebrand-acp` `fab95224…`, reporting
`0.3.25+31fc194cdafa`), model `qwen3-8b-q4_k_m.gguf` sha256 `b7185b73…11d1cf`,
`serve --max-seq-len 32768`, `rebrand-acp --max-tokens 8192`, thinking on
(nothing on this path sends `reasoning_effort`, and serve's default for qwen3 is
on). Two batches of ten, differing only in `--temperature`:

| batch | temperature | passes | failures |
|---|---|---|---|
| A | 0.0 (rebrand-acp's default) | **0/10** | 9 the answer's shape, 1 the model |
| B | 0.7 (serve's own default) | **3/10** | 2 the answer's shape, 3 the model, 2 an empty citation list refused by rebrand-acp |

**Retrieval is not what failed.** Every run reached `rebrand serve`, and the
loop, the MCP tools and the narrowing behaved as designed: `tools/list` offered
`search_messages`, then `read_thread` with the found IDs as an `enum`, then
nothing, and the answering turn carried the schema. The host published nothing
in any of the 17 failures. A pass costs 20–45 s in the loop, 1.4–1.5k input and
0.2–0.3k output tokens with 1.8–4.0k thinking tokens, and about 6.7 GB of VRAM
over idle (1,651 → 8,403 MiB) at 32,768 sequence length; `rebrand serve` was
ready in 1.0 s.

**The answer's shape: a serve-side constraint failure, not the model.** With the
schema in force the final string of `source_ids` never closes. The model writes
`'` where `"` belongs, so `']}` becomes string content, and the document runs on
until the grammar can close it:

```json
{"answer": "SOLVED-a0d7064c47bd", "source_ids": ["29885087…24f1cf']}{"
  , "source_ids"
  , "answer"
  , "SOLVED-a0d7064c47bd"
  , "29885087…24f1cf"
  ]}
```

That is schema-valid JSON, so `rebrand-acp` returns `end_turn`, and the host
refuses it: the citation is not an ID any `read_thread` returned. It fired in 9 of
the 11 greedy runs and 2 of the 10 at temperature 0.7. `grammar_repro.py` reduces
it to one request.

**Diagnosed and fixed by neil, aitaco-llc/rebrand#300 (`a8a0500`)**, reported in
`#buzz-platform` `0aeb45e9`. `ArrayScope::items()` credited an element only once it
reached a structural position of its array, so an array being written at its first
element read as holding nothing. The `minItems` deficit that followed denied the
tokens that close the string and the array together. His probe, against the real
qwen3-8b vocabulary at that prefix:

| token | id | at `31fc194` | fixed |
|---|---|---|---|
| `"` | 1 | allowed | allowed |
| `"]` | 1341 | **denied** | allowed |
| `"]}` | 92446 | **denied** | allowed |
| `']` | 660 | allowed | allowed |
| `']}` | 32741 | allowed | allowed |

The apostrophe twins were never denied, because they never leave the string, and
greedy takes the best survivor. So the condition is neither thinking nor greedy —
the mask is the same either way — but **an array with `minItems ≥ 1` closed at its
first element**, which every citation list of one is. Those decide only whether a
model reaches for a denied token. The same undercount let a one-item array take a
second element past `maxItems: 1`, which is schema-invalid output from a constraint
whose job is to prevent exactly that.

**A `maxItems: 5` schema like this one was never at risk**, and an earlier version
of this file's companion message said otherwise. neil compared the whole allowed
set at every position inside this array across qwen3-8b's 151,936-token vocabulary:
one position differs between the builds, by ten tokens, and all ten are the
`minItems` closers. The undercount was exactly one item, so it flips a `maxItems`
verdict only when the cap is 1. His remaining known limit — comma-denial masks are
untiered, so a token carrying two of an array's commas could overrun `maxItems` —
is also out of reach here: no token in this vocabulary carries more than one comma
of an array, for string or integer items.

## Re-run on the fix, Rebrand `530cd1f`: 4 of 10, and the shape failure is gone

2026-09-19 23:04–23:21Z, same host binary (sha256 `4dc50b3f71f9518c…`, byte-identical to the batch above),
same model, same flags, `rebrand-acp` back on its default temperature 0.0. The only variable is the Rebrand
build: `31fc194` → `530cd1f` (`rebrand` sha256 `eebab34d…`, `rebrand-acp` `7b3a9bb8…`, `0.3.25+530cd1f4ab20`).

| build | passes | answer-shape failures |
|---|---|---|
| `31fc194`, temperature 0.0 | 0/10 | 9 |
| `530cd1f`, temperature 0.0 | **4/10** | **0** |

Not one run showed the `']}` signature. Every remaining failure is the model's tool use, and five of the six are
one behaviour: it answers after `search_messages` without calling `read_thread` — citing the search hit, saying
the incident ID "does not match any available event_id", or (run 7) returning `source_ids: []`, which
`rebrand-acp` refused against the session schema. The sixth read the thread, found the right code, and cited the
channel's UUID alongside the resolution event, which the host refused.

A pass costs 43–154 s in the loop, 1.5–2.0k input and ~190 output tokens, and 3.6–11.2k thinking tokens: three of
the four passes spent four iterations and about 10k thinking tokens. The proof's own serve holds a 1.25 GB KV
pool and about 6.7 GB over idle; two runs' `vram.tsv` samples peak near the card's 24 GB limit because another
job shared the card, not because of this workload.

**The model's own failures** are qwen3-8b not using the narrowed tool: it reads
the `enum` as a list of candidate answers and replies that "the incident ID does
not match any available event IDs", instead of calling `read_thread` with the one
ID search returned. A tool description that says so explicitly is Stage 2 work.

**The two empty citation lists (B9, B10) were never constrained.** Both answered
while `read_thread` was still on offer, and `of-agent` sends a turn that has tools
without a `response_format` (`crates/of-agent/src/agent.rs:36-43`), so no automaton
saw that answer; `rebrand-acp` refused it afterwards against the session schema.
The schema the host sends does carry `minItems`, and
`test_empty_citation_list_from_an_unconstrained_turn` pins both halves: the
constrained turn's request carries `minItems: 1` and `maxItems: 5`, and the turn
that produced `[]` carried tools and no `response_format`.

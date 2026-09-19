# Rebrand-powered seat: end-to-end proof

Goal: **one Buzz seat, running on a local model served by Rebrand, answers one
mention.** It is the smallest proof that a seat can run on our own GPU instead
of Claude. The design is in `~/.buzz/RESEARCH/BUZZ_VS_REBRAND.md` §c.

```
owner ──mention──> local relay ──> buzz-acp ──ACP──> buzz-agent ──> llm_proxy.py ──> backend
                         ^                              │                           (stub | Ollama | rebrand serve)
                         └──── reply ── buzz CLI <── buzz-dev-mcp (shell tool)
```

No new adapter is involved. `buzz-agent` is already an ACP agent that speaks
OpenAI chat completions with tools, and `rebrand serve` (single-model mode)
accepts every field it sends.

## Run

```bash
# GPU-free. Proves the whole Buzz side against a strict stand-in for Rebrand.
scripts/rebrand-proof/run.sh stub

# Uses the GPU. Only when the GPU is scheduled for it.
OLLAMA_MODEL=qwen3-8b-q4km:latest scripts/rebrand-proof/run.sh ollama   # control
REBRAND_BIN=/path/to/rebrand REBRAND_MODEL=/path/to/model.gguf \
  scripts/rebrand-proof/run.sh rebrand                                   # the proof
```

Each run does the following:

- Starts its own Postgres, Redis and MinIO containers (`rebrand-proof-*`) and its own relay on `localhost:3950`.
- Admits the throwaway seat with `buzz relay members add`, the way `agentctl add-seat` does.
- Starts the backend and the recording proxy, then the seat, using the installed fleet binaries from `~/.local/bin`.
- Runs the seat in its own empty directory, `<run dir>/seat-cwd`, whatever directory you start the script from. The agent's shell tools work there, and its hint loader reads `AGENTS.md` from there and from `~`. So the prompt contains no hints unless you set `PROOF_SEAT_AGENTS_MD`.
- Sends one top-level mention: "@probe Reply in this thread with exactly: PONG-<nonce>".
- Waits for the reply, then tears everything down and appends one JSON line to `results.jsonl`.

All state lives in `$PROOF_STATE`, which defaults to `$BUZZ_AGENT_SCRATCH/rebrand-proof`. The script never touches `wss://buzz.aitaco.co`.

Set `CARGO_TARGET_DIR` (or `PROOF_RELAY_BIN` and `PROOF_ADMIN_BIN`) when the relay binaries were built outside this checkout.

The main knobs:

| setting | default |
|---|---|
| `PROOF_MAX_SEQ_LEN` | 32768 (passed to `rebrand serve --max-seq-len` and to `BUZZ_AGENT_MAX_CONTEXT_TOKENS`) |
| `PROOF_MAX_OUTPUT_TOKENS` | 2048 |
| `PROOF_MAX_ROUNDS` | 8 |
| `PROOF_TIMEOUT_S` | 900 |
| `REBRAND_EXTRA_ARGS` | none (e.g. `--max-batch-size 1`) |
| `PROOF_SEAT_AGENTS_MD` | none. A file to copy in as the seat's `AGENTS.md`, e.g. `~/.buzz/AGENTS.md` to match a fleet seat's prompt |

## What it records

One line per run, written by `summarize.py`. The field meanings are in its docstring.

| group | fields |
|---|---|
| verdict | `pass`, which requires all four: the reply carries the nonce, it is threaded under the mention, it came from the seat, and the turn outcome is `ok`. Also `reply_threaded`, `turn_outcome`, `reply_text` |
| latency | `mention_to_reply_s`, `mention_to_turn_start_s`, `turn_s`; `llm_s_first` (cold prefill of the whole system prompt), `llm_s_total`, `llm_s_max`; `serve_ready_s` (rebrand only) |
| size | `llm_calls`, `tool_calls`, `prompt_tokens_first` and `prompt_tokens_max` (as the backend reports them), `completion_tokens_total`, `prompt_chars_first`, `request_bytes_max` |
| contract | `unknown_fields` (request fields Rebrand would reject), `http_errors`, `finish_reasons` |
| GPU | `vram_baseline_mib`, `vram_peak_mib` (amdgpu sysfs, sampled at 1 Hz) |
| provenance | `mode`, `model_id`, `model_path`, `model_bytes`, `backend_version`, `max_seq_len`, `max_output_tokens`, the sha256 of each seat binary, `repo_commit` |
| prompt inputs | `seat_cwd`; `hint_agents_md` (each `AGENTS.md` the hint loader reads, with its bytes); `hint_bytes`; `hint_skill_files` |

Everything else stays in the run directory:

- `llm_calls.jsonl`: one line per model call
- `turnlog/`: the harness turn log, which holds the exact prompt and tool calls
- `seat.log`, `backend.log`, `relay.log`, `vram.tsv`

## Stub baseline (2026-09-18)

A `run.sh stub` run with fleet `buzz-acp` `e1750044`, `buzz-agent` `461635ba` and `buzz-dev-mcp` `a3f19606`:

- **Verdict:** `pass: true`. The reply was threaded under the mention and the turn outcome was `ok`.
- **Calls:** 2 LLM calls (a tool call, then `stop`) and 1 shell tool call.
- **Contract:** `unknown_fields: []` and no HTTP errors. So `buzz-agent`'s request is valid under Rebrand's `deny_unknown_fields` request struct (`rebrand_schema.py`).
- **Request size (2026-09-19, seat in its own directory):** the first request had 2 messages and 6 tools. The two cases:

  | seat hints | run | prompt characters | request size | ≈ tokens at 4 chars per token |
  |---|---|---|---|---|
  | none (the default) | `20260919T004452Z-stub` | 20,531 | 26.9 KB | 5.1k |
  | the nest's `AGENTS.md`, 3,659 bytes (`PROOF_SEAT_AGENTS_MD`) | `20260919T004516Z-stub` | 24,209 | 30.7 KB | 6.1k |

  Both are too big for `rebrand serve`'s default `--max-seq-len 4096`. The token figures are the stub's estimate (`stub_llm.py:50`), not a tokenizer's count.
- **Superseded:** the 2026-09-18 figure of 25,293 characters came from a seat that ran in the caller's directory, which was the nest. So the nest's `AGENTS.md` was in the prompt by accident.

## Open questions for Rebrand (for neil, when the GPU is scheduled)

1. **Build and model:** which `rebrand` build and which model and quantization to serve on HIP for a tool-calling chat seat.
   - On disk as GGUF: `~/.bernard/models/qwen2.5-3b-instruct-q4_k_m.gguf` and `~/.abracade/models/gemma-4-e2b-it-q4_k_m.gguf`.
   - Only as safetensors under `~/.cache/rebrand/hf-cache`: gemma-4-12B-it, Qwen3.8-27B, Muse-Glimmer-30B.
   - The `rebrand` binary at `~/dev/rebrand/target/release` is 0.3.17, built 2026-09-06.
2. **Serve flags:** anything besides `--max-seq-len 32768` that serve needs for this workload.
3. **Later, only if the proof works:**
   - prefix-cache reuse on HIP (each tool round re-prefills the whole transcript today)
   - a non-2xx status for request-level errors (today `finish_reason: "error"` comes back with HTTP 200)

#!/usr/bin/env bash
# N runs of the rebrand-acp proof, with the card rules that a single run cannot
# enforce for itself.
#
#   PROOF_BATCH_RUNS=10 \
#   PROOF_NATIVE_BIN=… PROOF_REBRAND_ACP_BIN=… REBRAND_BIN=… REBRAND_MODEL=… \
#     bash scripts/rebrand-proof/acp/batch.sh
#
# Every variable the kit reads is passed straight through; this adds three rules.
#
# 1. **Exit 75 stops the batch.** `native/run.sh` refuses to start when VRAM is
#    above its idle baseline, which means someone else is on the card. That guard
#    is evaluated per run, so inside a batch it fires and un-fires as a
#    neighbour's allocation moves: on 2026-09-19 it refused a run at 23:06:14Z and
#    the next attempt, 24 s later, ran anyway against a resident 32B model. A
#    refusal is evidence the card is shared for the whole batch, not a run to skip.
# 2. **Attempts are counted, not just rows.** It prints attempts, rows and
#    refusals at the end, because `results.jsonl` holds only the runs that
#    produced model output and a reader counting run directories finds more.
# 3. **One line per run**, so a batch that stops early says where.
set -uo pipefail

RUNS="${PROOF_BATCH_RUNS:-10}"
# PROOF_BATCH_KIT exists so the rules above can be tested against a stub run,
# with no card and no model.
KIT="${PROOF_BATCH_KIT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../native" && pwd)/run.sh}"
[[ -r "$KIT" ]] || { echo "batch: cannot read $KIT" >&2; exit 1; }

attempts=0
refusals=0
rows=0
for i in $(seq 1 "$RUNS"); do
  attempts=$((attempts + 1))
  printf '%s attempt %d/%d\n' "$(date -u +%H:%M:%SZ)" "$i" "$RUNS" >&2
  bash "$KIT"
  status=$?
  case "$status" in
    0) rows=$((rows + 1)) ;;
    75)
      refusals=$((refusals + 1))
      printf '%s attempt %d refused (exit 75): someone is on the card. Stopping the batch — %d of %d run.\n' \
        "$(date -u +%H:%M:%SZ)" "$i" "$((attempts - 1))" "$RUNS" >&2
      break
      ;;
    *) rows=$((rows + 1)) ;;  # a run that produced output and failed its checks
  esac
done

printf '%s batch done: %d attempts, %d rows, %d refusals\n' \
  "$(date -u +%H:%M:%SZ)" "$attempts" "$rows" "$refusals" >&2
(( refusals == 0 )) || exit 75

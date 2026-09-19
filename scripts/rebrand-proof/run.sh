#!/usr/bin/env bash
# End-to-end proof: one Buzz seat, driven by buzz-agent against a local model,
# answers one mention. See README.md in this directory.
#
#   run.sh stub      GPU-free: a strict stand-in for `rebrand serve`
#   run.sh ollama    control: the same seat against Ollama (uses the GPU)
#   run.sh rebrand   the proof: the same seat against `rebrand serve` (GPU)
#
# Everything runs on this machine: its own Postgres/Redis/MinIO containers,
# its own relay on 127.0.0.1, its own keys. Nothing touches wss://buzz.aitaco.co.
# Each run appends one JSON line to $PROOF_STATE/results.jsonl.
set -euo pipefail

MODE="${1:-}"
case "${MODE}" in
  stub|ollama|rebrand) ;;
  *) echo "usage: $0 stub|ollama|rebrand" >&2; exit 64 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "${HERE}" rev-parse --show-toplevel)"
STATE="${PROOF_STATE:-${BUZZ_AGENT_SCRATCH:-/tmp}/rebrand-proof}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${MODE}"
RUN_DIR="${STATE}/runs/${RUN_ID}"
RESULTS="${PROOF_RESULTS:-${STATE}/results.jsonl}"

# Binaries a real seat runs: the installed fleet builds by default.
BIN_DIR="${PROOF_BIN_DIR:-${HOME}/.local/bin}"
RELAY_BIN="${PROOF_RELAY_BIN:-${CARGO_TARGET_DIR:-${REPO}/target}/debug/buzz-relay}"
ADMIN_BIN="${PROOF_ADMIN_BIN:-${CARGO_TARGET_DIR:-${REPO}/target}/debug/buzz-admin}"

# Local infrastructure (ports and names chosen not to collide with dev setups).
PREFIX="${PROOF_CONTAINER_PREFIX:-rebrand-proof}"
RELAY_PORT="${PROOF_RELAY_PORT:-3950}"
PG_PORT="${PROOF_PG_PORT:-55440}"
REDIS_PORT="${PROOF_REDIS_PORT:-56390}"
MINIO_PORT="${PROOF_MINIO_PORT:-59010}"
PROXY_PORT="${PROOF_PROXY_PORT:-8098}"
STUB_PORT="${PROOF_STUB_PORT:-8099}"

# Model backends.
MAX_SEQ_LEN="${PROOF_MAX_SEQ_LEN:-32768}"
MAX_OUTPUT_TOKENS="${PROOF_MAX_OUTPUT_TOKENS:-2048}"
MAX_ROUNDS="${PROOF_MAX_ROUNDS:-8}"
REBRAND_BIN="${REBRAND_BIN:-}"
REBRAND_MODEL="${REBRAND_MODEL:-}"
REBRAND_PORT="${REBRAND_PORT:-8000}"
REBRAND_EXTRA_ARGS="${REBRAND_EXTRA_ARGS:-}"
OLLAMA_BASE="${OLLAMA_BASE:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-8b-q4km:latest}"
[[ "${OLLAMA_MODEL}" == *:* ]] || OLLAMA_MODEL="${OLLAMA_MODEL}:latest"   # Ollama reports tags in full
TIMEOUT_S="${PROOF_TIMEOUT_S:-900}"
SERVE_READY_TIMEOUT_S="${PROOF_SERVE_READY_TIMEOUT_S:-900}"

mkdir -p "${RUN_DIR}" "${STATE}/keys"
chmod 700 "${STATE}" "${STATE}/keys"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${RUN_DIR}/run.log" >&2; }
now() { date +%s.%N; }
put() { printf '%s' "$2" > "${RUN_DIR}/$1"; }   # one fact per file, read by summarize.py

PIDS=()
cleanup() {
  local code=$?
  for pid in "${PIDS[@]}"; do kill -TERM "${pid}" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do   # the relay closes sockets gracefully; give it time
    for _ in $(seq 1 20); do kill -0 "${pid}" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "${pid}" 2>/dev/null || true
  done
  # The card is shared: do not leave the control's model resident for Ollama's
  # keep-alive (5 min) after the run. Skip it if someone else had it loaded.
  if [[ "${MODE}" == "ollama" && "${OLLAMA_PRELOADED:-1}" == "0" ]]; then
    curl -sf -m 30 "${OLLAMA_BASE}/api/generate" \
      -d "{\"model\":\"${OLLAMA_MODEL}\",\"keep_alive\":0}" >/dev/null 2>&1 || true
  fi
  if [[ "${PROOF_KEEP_INFRA:-0}" != "1" ]]; then
    docker stop "${PREFIX}-pg" "${PREFIX}-redis" "${PREFIX}-minio" >/dev/null 2>&1 || true
  fi
  log "run ${RUN_ID} finished (exit ${code}); artifacts in ${RUN_DIR}"
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || [[ -x "$1" ]] || { echo "missing: $1" >&2; exit 69; }; }
for bin in buzz buzz-acp buzz-agent buzz-dev-mcp; do need "${BIN_DIR}/${bin}"; done
need "${RELAY_BIN}"; need "${ADMIN_BIN}"; need docker; need python3; need curl
# The card is shared. Refuse to start a GPU run on top of someone else's.
VRAM_IDLE_MAX_MIB="${PROOF_VRAM_IDLE_MAX_MIB:-3500}"
if [[ "${MODE}" != "stub" ]]; then
  vram_file="$(ls /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | head -1 || true)"
  if [[ -n "${vram_file}" ]]; then
    vram_mib=$(( $(cat "${vram_file}") / 1048576 ))
    if (( vram_mib > VRAM_IDLE_MAX_MIB )); then
      echo "VRAM in use is ${vram_mib} MiB, above the ${VRAM_IDLE_MAX_MIB} MiB idle baseline; someone is on the card" >&2
      exit 75
    fi
  fi
fi
if [[ "${MODE}" == "rebrand" ]]; then
  [[ -x "${REBRAND_BIN}" ]] || { echo "set REBRAND_BIN to a rebrand binary" >&2; exit 64; }
  [[ -f "${REBRAND_MODEL}" ]] || { echo "set REBRAND_MODEL to a GGUF file" >&2; exit 64; }
fi

# ── keys (persisted per state dir) ───────────────────────────────────────────
key() {  # key <name> -> writes keys/<name>.pub and keys/<name>.sec once
  local name="$1"
  if [[ ! -s "${STATE}/keys/${name}.sec" ]]; then
    local out; out="$("${ADMIN_BIN}" generate-key)"
    awk '/Public key/{print $3}' <<<"${out}" > "${STATE}/keys/${name}.pub"
    awk '/Private key|Secret key/{print $3}' <<<"${out}" > "${STATE}/keys/${name}.sec"
    chmod 600 "${STATE}/keys/${name}.sec"
  fi
}
for name in owner seat relay; do key "${name}"; done
OWNER_PUB="$(cat "${STATE}/keys/owner.pub")"
SEAT_PUB="$(cat "${STATE}/keys/seat.pub")"

bz() {  # bz <owner|seat> <buzz args...>
  local who="$1"; shift
  env -u BUZZ_AUTH_TAG BUZZ_RELAY_URL="http://localhost:${RELAY_PORT}" \
    BUZZ_PRIVATE_KEY="$(cat "${STATE}/keys/${who}.sec")" "${BIN_DIR}/buzz" "$@"
}

# ── local relay ──────────────────────────────────────────────────────────────
container() {  # container <name> <docker run args...>
  local name="${PREFIX}-$1"; shift
  if docker inspect "${name}" >/dev/null 2>&1; then
    docker start "${name}" >/dev/null
  else
    docker run -d --name "${name}" "$@" >/dev/null
  fi
}
log "starting local relay infrastructure"
container pg -e POSTGRES_USER=buzz -e POSTGRES_PASSWORD=buzz_dev -e POSTGRES_DB=buzz \
  -p "127.0.0.1:${PG_PORT}:5432" postgres:17-alpine
container redis -p "127.0.0.1:${REDIS_PORT}:6379" redis:7-alpine
# MinIO keeps its data in RAM and is recreated each run. The proof needs no
# object from an earlier run, and MinIO refuses every write once the disk that
# holds its data is 99% full (XMinioStorageFull), which hip's root disk can be.
docker rm -f "${PREFIX}-minio" >/dev/null 2>&1 || true
container minio -e MINIO_ROOT_USER=buzz_dev -e MINIO_ROOT_PASSWORD=buzz_dev_secret \
  --tmpfs /data:rw,size=1g \
  -p "127.0.0.1:${MINIO_PORT}:9000" quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z server /data
for _ in $(seq 1 60); do docker exec "${PREFIX}-pg" pg_isready -U buzz >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:${MINIO_PORT}/minio/health/live" >/dev/null && break; sleep 1; done
docker run --rm --network host --entrypoint /bin/sh quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z -c \
  "mc alias set local http://127.0.0.1:${MINIO_PORT} buzz_dev buzz_dev_secret >/dev/null && mc mb --ignore-existing local/buzz-media >/dev/null" \
  >>"${RUN_DIR}/run.log" 2>&1

cat > "${STATE}/relay.env" <<EOF
DATABASE_URL=postgres://buzz:buzz_dev@localhost:${PG_PORT}/buzz
REDIS_URL=redis://localhost:${REDIS_PORT}
BUZZ_BIND_ADDR=127.0.0.1:${RELAY_PORT}
RELAY_URL=ws://localhost:${RELAY_PORT}
BUZZ_RELAY_URL=ws://localhost:${RELAY_PORT}
BUZZ_REQUIRE_RELAY_MEMBERSHIP=true
RELAY_OWNER_PUBKEY=${OWNER_PUB}
BUZZ_RELAY_PRIVATE_KEY=$(cat "${STATE}/keys/relay.sec")
BUZZ_PUSH_ENABLED=false
BUZZ_S3_ENDPOINT=http://localhost:${MINIO_PORT}
BUZZ_S3_ACCESS_KEY=buzz_dev
BUZZ_S3_SECRET_KEY=buzz_dev_secret
BUZZ_S3_BUCKET=buzz-media
BUZZ_S3_REGION=us-east-1
BUZZ_S3_ADDRESSING_STYLE=path
RUST_LOG=buzz_relay=info
EOF
chmod 600 "${STATE}/relay.env"
(set -a; . "${STATE}/relay.env"; set +a; "${ADMIN_BIN}" migrate) >>"${RUN_DIR}/run.log" 2>&1
(set -a; . "${STATE}/relay.env"; set +a; exec "${RELAY_BIN}") >"${RUN_DIR}/relay.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:${RELAY_PORT}/_liveness" >/dev/null && break; sleep 1; done
curl -sf "http://127.0.0.1:${RELAY_PORT}/_liveness" >/dev/null || { log "relay did not come up"; exit 70; }

# The seat is admitted the way agentctl admits a seat: `buzz relay members add`.
bz owner --format compact relay members add --pubkey "${SEAT_PUB}" --role member >>"${RUN_DIR}/run.log"
if [[ ! -s "${STATE}/channel" ]]; then
  bz owner --format compact channels create --name "rebrand-proof" --type stream --visibility open \
    --description "Rebrand seat proof" | python3 -c 'import json,sys; print(json.load(sys.stdin)["channel_id"])' \
    > "${STATE}/channel"
fi
CHANNEL="$(cat "${STATE}/channel")"
bz owner channels add-member --channel "${CHANNEL}" --pubkey "${SEAT_PUB}" >>"${RUN_DIR}/run.log" 2>&1 || true
log "relay up on 127.0.0.1:${RELAY_PORT}, channel ${CHANNEL}"

# ── model backend ────────────────────────────────────────────────────────────
VRAM_FILE="$(ls /sys/class/drm/card*/device/mem_info_vram_used 2>/dev/null | head -1 || true)"
if [[ "${MODE}" != "stub" && -n "${VRAM_FILE}" ]]; then
  (while :; do printf '%s\t%s\n' "$(now)" "$(cat "${VRAM_FILE}")"; sleep 1; done) > "${RUN_DIR}/vram.tsv" &
  PIDS+=($!)
fi

case "${MODE}" in
  stub)
    python3 "${HERE}/stub_llm.py" --port "${STUB_PORT}" 2>"${RUN_DIR}/backend.log" &
    PIDS+=($!)
    BACKEND="http://127.0.0.1:${STUB_PORT}"
    MODEL_ID="stub"
    for _ in $(seq 1 30); do curl -sf "${BACKEND}/health" >/dev/null && break; sleep 0.2; done
    ;;
  ollama)
    BACKEND="${OLLAMA_BASE}"
    MODEL_ID="${OLLAMA_MODEL}"
    curl -sf "${BACKEND}/v1/models" | grep -q "\"${MODEL_ID}\"" \
      || { log "Ollama at ${BACKEND} does not list ${MODEL_ID}"; exit 69; }
    put backend_version "ollama $(curl -sf "${BACKEND}/api/version" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))')"
    OLLAMA_PRELOADED="$(curl -sf "${BACKEND}/api/ps" | python3 -c 'import json,sys; m=sys.argv[1]; print(int(any(m in (x.get("name"), x.get("model")) for x in json.load(sys.stdin).get("models",[]))))' "${MODEL_ID}")"
    blob="$(curl -sf "${BACKEND}/api/show" -d "{\"model\":\"${MODEL_ID}\"}" \
      | python3 -c 'import json,sys; print(next((l[5:] for l in json.load(sys.stdin).get("modelfile", "").splitlines() if l.startswith("FROM /")), ""))')"
    if [[ -n "${blob}" ]]; then
      put model_path "${blob}"
      put model_bytes "$(stat -c %s "${blob}")"
      put model_sha256 "${blob##*/sha256-}"   # Ollama names each blob by its sha256
    fi
    ;;
  rebrand)
    if ss -ltn 2>/dev/null | grep -q ":${REBRAND_PORT} "; then
      log "port ${REBRAND_PORT} is in use; refusing to share it"; exit 69
    fi
    put backend_version "$("${REBRAND_BIN}" --version 2>&1 | head -1)"
    put backend_sha256 "$(sha256sum "${REBRAND_BIN}" | cut -c1-16)"   # a path can be rebuilt under you
    put model_path "${REBRAND_MODEL}"
    put model_bytes "$(stat -c %s "${REBRAND_MODEL}")"
    put model_sha256 "$(sha256sum "${REBRAND_MODEL}" | cut -d' ' -f1)"
    serve_started="$(now)"
    # shellcheck disable=SC2086 # REBRAND_EXTRA_ARGS is a flag list by design
    "${REBRAND_BIN}" serve --model "${REBRAND_MODEL}" --host 127.0.0.1 --port "${REBRAND_PORT}" \
      --max-seq-len "${MAX_SEQ_LEN}" ${REBRAND_EXTRA_ARGS} >"${RUN_DIR}/backend.log" 2>&1 &
    PIDS+=($!)
    BACKEND="http://127.0.0.1:${REBRAND_PORT}"
    deadline=$(( $(date +%s) + SERVE_READY_TIMEOUT_S ))
    until curl -sf "${BACKEND}/health" >/dev/null; do
      (( $(date +%s) < deadline )) || { log "rebrand serve not ready after ${SERVE_READY_TIMEOUT_S}s"; exit 70; }
      sleep 1
    done
    put serve_ready_s "$(python3 -c "print(round($(now) - ${serve_started}, 2))")"
    MODEL_ID="$(curl -sf "${BACKEND}/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
    ;;
esac
put mode "${MODE}"; put model_id "${MODEL_ID}"; put backend "${BACKEND}"
put max_seq_len "${MAX_SEQ_LEN}"; put max_output_tokens "${MAX_OUTPUT_TOKENS}"
log "backend ${MODE} at ${BACKEND}, model ${MODEL_ID}"

python3 "${HERE}/llm_proxy.py" --listen "${PROXY_PORT}" --backend "${BACKEND}" \
  --log "${RUN_DIR}/llm_calls.jsonl" --timeout "${TIMEOUT_S}" 2>"${RUN_DIR}/proxy.log" &
PIDS+=($!)
sleep 0.5

# ── the seat ─────────────────────────────────────────────────────────────────
for bin in buzz-acp buzz-agent buzz-dev-mcp buzz; do
  printf '%s %s\n' "${bin}" "$(sha256sum "${BIN_DIR}/${bin}" | cut -c1-16)"
done > "${RUN_DIR}/binaries"
git -C "${REPO}" rev-parse HEAD > "${RUN_DIR}/repo_commit"

# The seat runs in a fresh directory of its own, never the caller's. buzz-acp
# hands its working directory to the agent (crates/buzz-acp/src/lib.rs:81): the
# agent's shell tools work there, and its hint loader puts AGENTS.md files from
# there (and ~/AGENTS.md) into the prompt (crates/buzz-agent/src/hints.rs).
# PROOF_SEAT_AGENTS_MD copies one AGENTS.md in on purpose, e.g. the nest's, to
# match a fleet seat's prompt.
SEAT_CWD="${RUN_DIR}/seat-cwd"
mkdir -p "${SEAT_CWD}"
if [[ -n "${PROOF_SEAT_AGENTS_MD:-}" ]]; then
  cp "${PROOF_SEAT_AGENTS_MD}" "${SEAT_CWD}/AGENTS.md"
fi
put seat_cwd "${SEAT_CWD}"
# What the hint loader will read, mirroring hints.rs: AGENTS.md along the git
# root -> cwd chain (cwd alone outside a repo), ~/AGENTS.md first, and SKILL.md
# files under the skill directories.
python3 - "${SEAT_CWD}" "${HOME}" > "${RUN_DIR}/hint_files.json" <<'PY'
import json, os, sys
cwd, home = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
root, d = None, cwd
while True:
    if os.path.exists(os.path.join(d, ".git")):
        root = d
        break
    if os.path.dirname(d) == d:
        break
    d = os.path.dirname(d)
chain = [cwd]
if root:
    chain, d = [], cwd
    while d.startswith(root):
        chain.insert(0, d)
        if d == root:
            break
        d = os.path.dirname(d)
if home not in chain:
    chain.insert(0, home)
files = [{"path": p, "bytes": os.path.getsize(p)}
         for p in (os.path.join(c, "AGENTS.md") for c in chain) if os.path.isfile(p)]
skill_dirs = [os.path.join(cwd, s) for s in (".agents/skills", ".goose/skills", ".claude/skills")]
skill_dirs.append(os.path.join(home, ".agents/skills"))
skills = sum(1 for sd in skill_dirs if os.path.isdir(sd)
             for _, _, fs in os.walk(sd) for f in fs if f == "SKILL.md")
json.dump({"agents_md": files, "skill_md_files": skills}, sys.stdout)
PY
log "seat cwd ${SEAT_CWD}; hint files $(cat "${RUN_DIR}/hint_files.json")"

( cd "${SEAT_CWD}" && exec env -i HOME="${HOME}" USER="${USER}" PATH="${BIN_DIR}:/usr/bin:/bin" NO_COLOR=1 \
  BUZZ_RELAY_URL="ws://localhost:${RELAY_PORT}" \
  BUZZ_PRIVATE_KEY="$(cat "${STATE}/keys/seat.sec")" \
  BUZZ_ACP_AGENT_COMMAND=buzz-agent \
  BUZZ_ACP_MCP_COMMAND=buzz-dev-mcp \
  BUZZ_ACP_RESPOND_TO=anyone \
  BUZZ_ACP_SESSION_POLICY=thread \
  BUZZ_ACP_SYSTEM_PROMPT_FILE="${HERE}/persona.md" \
  BUZZ_ACP_TURN_LOG_DIR="${RUN_DIR}/turnlog" \
  BUZZ_ACP_IDLE_TIMEOUT="${TIMEOUT_S}" \
  BUZZ_ACP_MAX_TURN_DURATION="$(( TIMEOUT_S * 2 ))" \
  BUZZ_AGENT_PROVIDER=openai \
  OPENAI_COMPAT_API=chat \
  OPENAI_COMPAT_BASE_URL="http://127.0.0.1:${PROXY_PORT}/v1" \
  OPENAI_COMPAT_MODEL="${MODEL_ID}" \
  OPENAI_COMPAT_API_KEY=local-proof \
  BUZZ_AGENT_MAX_CONTEXT_TOKENS="${MAX_SEQ_LEN}" \
  BUZZ_AGENT_MAX_OUTPUT_TOKENS="${MAX_OUTPUT_TOKENS}" \
  BUZZ_AGENT_MAX_ROUNDS="${MAX_ROUNDS}" \
  BUZZ_AGENT_REQUIRE_REPLY=1 \
  BUZZ_AGENT_LLM_TIMEOUT_SECS="${TIMEOUT_S}" \
  RUST_LOG=buzz_acp=info,buzz_agent=info \
  "${BIN_DIR}/buzz-acp" ) >"${RUN_DIR}/seat.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do grep -q "subscribed to channel" "${RUN_DIR}/seat.log" && break; sleep 1; done
grep -q "subscribed to channel" "${RUN_DIR}/seat.log" || { log "seat did not subscribe"; exit 70; }
sleep 2

# ── one mention, one reply ───────────────────────────────────────────────────
NONCE="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
put nonce "${NONCE}"
put t_mention "$(now)"
bz owner --format compact messages send --channel "${CHANNEL}" \
  --content "@probe Reply in this thread with exactly: PONG-${NONCE}" --mention "${SEAT_PUB}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["event_id"])' > "${RUN_DIR}/trigger_id"
log "mention $(cat "${RUN_DIR}/trigger_id") sent; waiting up to ${TIMEOUT_S}s for PONG-${NONCE}"

deadline=$(( $(date +%s) + TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  if bz owner messages get --channel "${CHANNEL}" --limit 20 2>/dev/null | python3 -c '
import json, sys
seat, nonce = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
rows = data if isinstance(data, list) else data.get("messages", [])
for row in rows:
    if row.get("pubkey") == seat and f"PONG-{nonce}" in (row.get("content") or ""):
        json.dump(row, sys.stdout)
        sys.exit(0)
sys.exit(1)' "${SEAT_PUB}" "${NONCE}" > "${RUN_DIR}/reply.json"; then
    put t_reply_observed "$(now)"
    log "reply seen"
    break
  fi
  sleep 1
done
[[ -s "${RUN_DIR}/reply.json" ]] || log "no reply within ${TIMEOUT_S}s"

# Let the turn close so its index line is written.
for _ in $(seq 1 90); do
  cat "${RUN_DIR}"/turnlog/index/*.jsonl 2>/dev/null | grep -q . && break
  sleep 1
done
kill -TERM "${PIDS[-1]}" 2>/dev/null || true   # the seat: flushes the turn log on exit
sleep 4

case "${MODE}" in
  ollama)   # Ollama picks its own default context; read what it loaded with.
    put backend_context_len "$(curl -sf "${BACKEND}/api/ps" | python3 -c 'import json,sys; m=sys.argv[1]; print(next((x.get("context_length","") for x in json.load(sys.stdin).get("models",[]) if m in (x.get("name"), x.get("model"))), ""))' "${MODEL_ID}")" ;;
  rebrand) put backend_context_len "${MAX_SEQ_LEN}" ;;
esac

python3 "${HERE}/summarize.py" --run-dir "${RUN_DIR}" --seat "${SEAT_PUB}" --results "${RESULTS}"

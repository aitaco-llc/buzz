#!/usr/bin/env bash
# End-to-end proof: Rebrand of-agent retrieves a seeded fact through Buzz.
# No buzz-agent, developer MCP, or model-controlled shell. See ../README.md.
#
# Everything runs on this machine: its own Postgres/Redis/MinIO containers,
# its own relay on 127.0.0.1, its own keys. Nothing touches wss://buzz.aitaco.co.
# Each run appends one JSON line to $PROOF_STATE/results.jsonl.
set -euo pipefail

NATIVE_BIN="${PROOF_NATIVE_BIN:?set PROOF_NATIVE_BIN to the compiled Rebrand loop worker}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
REPO="$(git -C "${HERE}" rev-parse --show-toplevel)"
STATE="${PROOF_STATE:-${BUZZ_AGENT_SCRATCH:-/tmp}/rebrand-native-proof}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-rebrand"
RUN_DIR="${STATE}/runs/${RUN_ID}"
RESULTS="${PROOF_RESULTS:-${STATE}/results.jsonl}"

# Binaries a real seat runs: the installed fleet builds by default.
BIN_DIR="${PROOF_BIN_DIR:-${HOME}/.local/bin}"
RELAY_BIN="${PROOF_RELAY_BIN:-${CARGO_TARGET_DIR:-${REPO}/target}/debug/buzz-relay}"
ADMIN_BIN="${PROOF_ADMIN_BIN:-${CARGO_TARGET_DIR:-${REPO}/target}/debug/buzz-admin}"

# Local infrastructure (ports and names chosen not to collide with dev setups).
PREFIX="${PROOF_CONTAINER_PREFIX:-rebrand-native-proof}"
RELAY_PORT="${PROOF_RELAY_PORT:-3967}"
PG_PORT="${PROOF_PG_PORT:-55467}"
REDIS_PORT="${PROOF_REDIS_PORT:-56367}"
MINIO_PORT="${PROOF_MINIO_PORT:-59067}"

# Local inference backend.
MAX_SEQ_LEN="${PROOF_MAX_SEQ_LEN:-8192}"
REBRAND_BIN="${REBRAND_BIN:-}"
REBRAND_MODEL="${REBRAND_MODEL:-}"
REBRAND_PORT="${REBRAND_PORT:-8000}"
REBRAND_EXTRA_ARGS="${REBRAND_EXTRA_ARGS:-}"
TIMEOUT_S="${PROOF_TIMEOUT_S:-210}"
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
  if [[ "${PROOF_KEEP_INFRA:-0}" != "1" ]]; then
    docker stop "${PREFIX}-pg" "${PREFIX}-redis" "${PREFIX}-minio" >/dev/null 2>&1 || true
  fi
  log "run ${RUN_ID} finished (exit ${code}); artifacts in ${RUN_DIR}"
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null || [[ -x "$1" ]] || { echo "missing: $1" >&2; exit 69; }; }
for bin in buzz buzz-acp; do need "${BIN_DIR}/${bin}"; done
need "${NATIVE_BIN}"; need "${RELAY_BIN}"; need "${ADMIN_BIN}"; need docker; need python3; need curl
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
container minio -e MINIO_ROOT_USER=buzz_dev -e MINIO_ROOT_PASSWORD=buzz_dev_secret \
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
BUZZ_HEALTH_PORT=${PROOF_HEALTH_PORT:-18067}
BUZZ_METRICS_PORT=${PROOF_METRICS_PORT:-19167}
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
if [[ -n "${VRAM_FILE}" ]]; then
  (while :; do printf '%s\t%s\n' "$(now)" "$(cat "${VRAM_FILE}")"; sleep 1; done) > "${RUN_DIR}/vram.tsv" &
  PIDS+=($!)
fi

if ss -ltn 2>/dev/null | grep -q ":${REBRAND_PORT} "; then
  log "port ${REBRAND_PORT} is in use; refusing to share it"; exit 69
fi
put backend_version "$("${REBRAND_BIN}" --version 2>&1 | head -1)"
put model_path "${REBRAND_MODEL}"
put model_bytes "$(stat -c %s "${REBRAND_MODEL}")"
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
put mode rebrand; put model_id "${MODEL_ID}"; put backend "${BACKEND}"
put max_seq_len "${MAX_SEQ_LEN}"
log "backend rebrand at ${BACKEND}, model ${MODEL_ID}"

# ── the seat ─────────────────────────────────────────────────────────────────
for bin in buzz-acp buzz; do
  printf '%s %s\n' "${bin}" "$(sha256sum "${BIN_DIR}/${bin}" | cut -c1-16)"
done > "${RUN_DIR}/binaries"
git -C "${REPO}" rev-parse HEAD > "${RUN_DIR}/repo_commit"

NONCE="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
LOOKUP="incident $(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
QUESTION="Find ${LOOKUP}, read its thread, and report the recovery code with a source citation."
SOURCE_ROOT="$(bz owner messages send --channel "${CHANNEL}" --content "Incident ${LOOKUP}: worker failed; see thread for resolution." | python3 -c 'import json,sys; print(json.load(sys.stdin)["event_id"])')"
bz owner messages send --channel "${CHANNEL}" --reply-to "${SOURCE_ROOT}" \
  --content "Resolution: restart the worker using recovery code SOLVED-${NONCE}." \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["event_id"])' > "${RUN_DIR}/source_id"
put nonce "${NONCE}"
put lookup "${LOOKUP}"
sha256sum "${NATIVE_BIN}" > "${RUN_DIR}/native_binary"
env -i HOME="${HOME}" USER="${USER}" PATH="${BIN_DIR}:/usr/bin:/bin" NO_COLOR=1 \
  BUZZ_RELAY_URL="ws://localhost:${RELAY_PORT}" \
  BUZZ_PRIVATE_KEY="$(cat "${STATE}/keys/seat.sec")" \
  BUZZ_ACP_AGENT_COMMAND="${NATIVE_BIN}" \
  BUZZ_ACP_MCP_COMMAND="" \
  BUZZ_ACP_NO_MEMORY=true \
  BUZZ_ACP_RESPOND_TO=anyone \
  BUZZ_ACP_SESSION_POLICY=thread \
  BUZZ_ACP_TURN_LOG_DIR="${RUN_DIR}/turnlog" \
  BUZZ_ACP_IDLE_TIMEOUT="${TIMEOUT_S}" \
  BUZZ_ACP_MAX_TURN_DURATION="$(( TIMEOUT_S * 2 ))" \
  REBRAND_ENDPOINT="${BACKEND}" REBRAND_MODEL_ID="${MODEL_ID}" \
  PROOF_CHANNEL="${CHANNEL}" PROOF_QUESTION="${QUESTION}" \
  PROOF_TRIGGER_FILE="${RUN_DIR}/trigger_id" PROOF_NATIVE_RESULT="${RUN_DIR}/native.json" \
  RUST_LOG=buzz_acp=info \
  "${BIN_DIR}/buzz-acp" >"${RUN_DIR}/seat.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do grep -q "subscribed to channel" "${RUN_DIR}/seat.log" && break; sleep 1; done
grep -q "subscribed to channel" "${RUN_DIR}/seat.log" || { log "seat did not subscribe"; exit 70; }
sleep 2

# ── one mention, one reply ───────────────────────────────────────────────────
put t_mention "$(now)"
bz owner --format compact messages send --channel "${CHANNEL}" \
  --content "${QUESTION}" --mention "${SEAT_PUB}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["event_id"])' > "${RUN_DIR}/trigger_id"
log "mention $(cat "${RUN_DIR}/trigger_id") sent; waiting up to ${TIMEOUT_S}s for SOLVED-${NONCE}"

deadline=$(( $(date +%s) + TIMEOUT_S ))
while (( $(date +%s) < deadline )); do
  if bz owner messages get --channel "${CHANNEL}" --limit 20 2>/dev/null | python3 -c '
import json, sys
seat, nonce = sys.argv[1], sys.argv[2]
data = json.load(sys.stdin)
rows = data if isinstance(data, list) else data.get("messages", [])
for row in rows:
    if row.get("pubkey") == seat and f"SOLVED-{nonce}" in (row.get("content") or ""):
        json.dump(row, sys.stdout)
        sys.exit(0)
sys.exit(1)' "${SEAT_PUB}" "${NONCE}" > "${RUN_DIR}/reply.json"; then
    put t_reply_observed "$(now)"
    log "reply seen"
    break
  fi
  if compgen -G "${RUN_DIR}/turnlog/index/*.jsonl" >/dev/null; then
    log "turn ended without a matching reply"
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

python3 "${HERE}/native/summarize.py" --run-dir "${RUN_DIR}" --seat "${SEAT_PUB}" --results "${RESULTS}"

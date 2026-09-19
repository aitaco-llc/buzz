#!/usr/bin/env bash
# Voice-bridge lab: the V1 call path end to end on this machine.
#
# Throwaway keys, its own relay on 127.0.0.1 (Postgres/Redis/MinIO containers),
# a scripted fake Gemini, and a stub seat running buzz-acp with the self-wake
# opt-in. Nothing touches wss://buzz.aitaco.co and no Gemini call is made.
#
# A phone-shaped call: the caller creates the huddle's backing channel, posts
# kind:48100 in its DM with the seat, joins the audio room and talks. The
# bridge must join, hand Gemini the audio, post an ask that wakes the seat,
# carry the seat's answer back, resume the Gemini session after goAway, speak
# into the room, and post the transcript. lab_check.py scores it.
#
# LAB_FAULT forces a failure instead, to prove that a call which dies still
# writes an ending naming the cause:
#   room_join      the huddle names a channel that does not exist
#   gemini_connect the Gemini endpoint refuses the connection
#   mid_call       Gemini disappears mid-call, past its reconnect budget
#   relay_gone     the relay dies mid-call, under both sockets at once
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "${HERE}" rev-parse --show-toplevel)"
STATE="${LAB_STATE:-${BUZZ_AGENT_SCRATCH:-/tmp}/voice-bridge-lab}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${STATE}/runs/${RUN_ID}"
TARGET="${CARGO_TARGET_DIR:-${REPO}/target}"
# The bridge is its own workspace (crates/buzz-voice-bridge/Cargo.toml).
BRIDGE_TARGET="${LAB_BRIDGE_TARGET:-${CARGO_TARGET_DIR:-${REPO}/crates/buzz-voice-bridge/target}}"

BUZZ_BIN="${LAB_BUZZ_BIN:-${HOME}/.local/bin/buzz}"
ACP_BIN="${LAB_ACP_BIN:?set LAB_ACP_BIN to a buzz-acp that has --self-wake-tag}"
BRIDGE_BIN="${LAB_BRIDGE_BIN:-${BRIDGE_TARGET}/debug/buzz-voice-bridge}"
CALLER_BIN="${LAB_CALLER_BIN:-${BRIDGE_TARGET}/debug/examples/fake_caller}"
RELAY_BIN="${LAB_RELAY_BIN:-${TARGET}/debug/buzz-relay}"
ADMIN_BIN="${LAB_ADMIN_BIN:-${TARGET}/debug/buzz-admin}"

PREFIX="${LAB_CONTAINER_PREFIX:-voice-bridge-lab}"
RELAY_PORT="${LAB_RELAY_PORT:-3968}"
PG_PORT="${LAB_PG_PORT:-55468}"
REDIS_PORT="${LAB_REDIS_PORT:-56368}"
MINIO_PORT="${LAB_MINIO_PORT:-59068}"
GEMINI_PORT="${LAB_GEMINI_PORT:-18090}"
RELAY_URL="ws://localhost:${RELAY_PORT}"

mkdir -p "${RUN_DIR}" "${STATE}/keys"
date +%s > "${RUN_DIR}/t_start"   # keys and the DM persist; score only this run's events
chmod 700 "${STATE}" "${STATE}/keys"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "${RUN_DIR}/lab.log" >&2; }

PIDS=()
cleanup() {
  local code=$?
  for pid in "${PIDS[@]}"; do kill -TERM "${pid}" 2>/dev/null || true; done
  for pid in "${PIDS[@]}"; do
    for _ in $(seq 1 20); do kill -0 "${pid}" 2>/dev/null || break; sleep 0.5; done
    kill -KILL "${pid}" 2>/dev/null || true
  done
  [[ "${LAB_KEEP_INFRA:-0}" == "1" ]] || \
    docker stop "${PREFIX}-pg" "${PREFIX}-redis" "${PREFIX}-minio" >/dev/null 2>&1 || true
  log "lab ${RUN_ID} finished (exit ${code}); artifacts in ${RUN_DIR}"
}
trap cleanup EXIT

for bin in "${BUZZ_BIN}" "${ACP_BIN}" "${BRIDGE_BIN}" "${CALLER_BIN}" "${RELAY_BIN}" "${ADMIN_BIN}"; do
  [[ -x "${bin}" ]] || { echo "missing: ${bin}" >&2; exit 69; }
done
"${ACP_BIN}" --help | grep -q -- --self-wake-tag || { echo "${ACP_BIN} has no --self-wake-tag" >&2; exit 69; }
for bin in "${BUZZ_BIN}" "${ACP_BIN}" "${BRIDGE_BIN}" "${CALLER_BIN}" "${RELAY_BIN}"; do
  printf '%s %s\n' "$(basename "${bin}")" "$(sha256sum "${bin}" | cut -c1-16)"
done > "${RUN_DIR}/binaries"
git -C "${REPO}" rev-parse HEAD > "${RUN_DIR}/repo_commit"

# ── keys: throwaway identities, one env file each ────────────────────────────
key() {
  local name="$1"
  if [[ ! -s "${STATE}/keys/${name}.env" ]]; then
    local out; out="$("${ADMIN_BIN}" generate-key)"
    printf 'BUZZ_PRIVATE_KEY=%s\n' "$(awk '/Private key|Secret key/{print $3}' <<<"${out}")" > "${STATE}/keys/${name}.env"
    awk '/Public key/{print $3}' <<<"${out}" > "${STATE}/keys/${name}.pub"
    chmod 600 "${STATE}/keys/${name}.env"
  fi
}
for name in caller seat relay; do key "${name}"; done
CALLER_PUB="$(cat "${STATE}/keys/caller.pub")"
SEAT_PUB="$(cat "${STATE}/keys/seat.pub")"
as() {  # as <caller|seat> <buzz args...>
  local who="$1"; shift
  env -u BUZZ_AUTH_TAG BUZZ_RELAY_URL="http://localhost:${RELAY_PORT}" \
    BUZZ_PRIVATE_KEY="$(sed -n 's/^BUZZ_PRIVATE_KEY=//p' "${STATE}/keys/${who}.env")" "${BUZZ_BIN}" "$@"
}

# ── local relay ──────────────────────────────────────────────────────────────
container() {
  local name="${PREFIX}-$1"; shift
  if docker inspect "${name}" >/dev/null 2>&1; then docker start "${name}" >/dev/null
  else docker run -d --name "${name}" "$@" >/dev/null; fi
}
log "starting local relay infrastructure"
container pg -e POSTGRES_USER=buzz -e POSTGRES_PASSWORD=buzz_dev -e POSTGRES_DB=buzz \
  -p "127.0.0.1:${PG_PORT}:5432" postgres:17-alpine
container redis -p "127.0.0.1:${REDIS_PORT}:6379" redis:7-alpine
docker rm -f "${PREFIX}-minio" >/dev/null 2>&1 || true
container minio -e MINIO_ROOT_USER=buzz_dev -e MINIO_ROOT_PASSWORD=buzz_dev_secret \
  --tmpfs /data:rw,size=256m -p "127.0.0.1:${MINIO_PORT}:9000" \
  quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z server /data
for _ in $(seq 1 60); do docker exec "${PREFIX}-pg" pg_isready -U buzz >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:${MINIO_PORT}/minio/health/live" >/dev/null && break; sleep 1; done
docker run --rm --network host --entrypoint /bin/sh quay.io/minio/mc:RELEASE.2025-08-13T08-35-41Z -c \
  "mc alias set local http://127.0.0.1:${MINIO_PORT} buzz_dev buzz_dev_secret >/dev/null && mc mb --ignore-existing local/buzz-media >/dev/null" \
  >>"${RUN_DIR}/lab.log" 2>&1
cat > "${STATE}/relay.env" <<ENV
DATABASE_URL=postgres://buzz:buzz_dev@localhost:${PG_PORT}/buzz
REDIS_URL=redis://localhost:${REDIS_PORT}
BUZZ_BIND_ADDR=127.0.0.1:${RELAY_PORT}
BUZZ_HEALTH_PORT=${LAB_HEALTH_PORT:-18068}
BUZZ_METRICS_PORT=${LAB_METRICS_PORT:-19168}
RELAY_URL=${RELAY_URL}
BUZZ_RELAY_URL=${RELAY_URL}
BUZZ_REQUIRE_RELAY_MEMBERSHIP=true
RELAY_OWNER_PUBKEY=${CALLER_PUB}
BUZZ_RELAY_PRIVATE_KEY=$(sed -n 's/^BUZZ_PRIVATE_KEY=//p' "${STATE}/keys/relay.env")
BUZZ_PUSH_ENABLED=false
BUZZ_S3_ENDPOINT=http://localhost:${MINIO_PORT}
BUZZ_S3_ACCESS_KEY=buzz_dev
BUZZ_S3_SECRET_KEY=buzz_dev_secret
BUZZ_S3_BUCKET=buzz-media
BUZZ_S3_REGION=us-east-1
BUZZ_S3_ADDRESSING_STYLE=path
RUST_LOG=buzz_relay=info
ENV
chmod 600 "${STATE}/relay.env"
(set -a; . "${STATE}/relay.env"; set +a; "${ADMIN_BIN}" migrate) >>"${RUN_DIR}/lab.log" 2>&1
(set -a; . "${STATE}/relay.env"; set +a; exec "${RELAY_BIN}") >"${RUN_DIR}/relay.log" 2>&1 &
RELAY_PID=$!
PIDS+=("${RELAY_PID}")
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:${RELAY_PORT}/_liveness" >/dev/null && break; sleep 1; done
curl -sf "http://127.0.0.1:${RELAY_PORT}/_liveness" >/dev/null || { log "relay did not come up"; exit 70; }
as caller --format compact relay members add --pubkey "${SEAT_PUB}" --role member >>"${RUN_DIR}/lab.log"
as caller --format compact dms open --pubkey "${SEAT_PUB}" > "${RUN_DIR}/dm-open.json"
DM="$(grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "${RUN_DIR}/dm-open.json" | head -1)"
[[ -n "${DM}" ]] || { log "no DM id in $(cat "${RUN_DIR}/dm-open.json")"; exit 70; }
echo "${DM}" > "${RUN_DIR}/dm"
log "relay up on ${RELAY_URL}; DM ${DM}"

# ── Gemini: the scripted fake by default; LAB_GEMINI=real uses the real API ──
# The real mode reads the key from Secret Manager the way production does and
# needs LAB_CALLER_PCM (s16le 48 kHz mono speech) for the caller to say.
LAB_GEMINI="${LAB_GEMINI:-fake}"
echo "${LAB_GEMINI}" > "${RUN_DIR}/gemini_mode"
LAB_FAULT="${LAB_FAULT:-none}"
echo "${LAB_FAULT}" > "${RUN_DIR}/fault"
if [[ "${LAB_GEMINI}" == "fake" ]]; then
  FAKE_GEMINI_LOG="${RUN_DIR}/gemini.jsonl" python3 "${HERE}/fake_gemini.py" "${GEMINI_PORT}" \
    >"${RUN_DIR}/gemini.log" 2>&1 &
  FAKE_GEMINI_PID=$!
  PIDS+=("${FAKE_GEMINI_PID}")
  GEMINI_ENV=(VOICE_BRIDGE_GEMINI_URL="ws://127.0.0.1:${GEMINI_PORT}" GEMINI_API_KEY=lab-key)
  CALLER_TALK=(--talk-secs 3 --listen-secs "${LAB_LISTEN_S:-25}")
else
  [[ -f "${LAB_CALLER_PCM:-}" ]] || { echo "LAB_GEMINI=real needs LAB_CALLER_PCM" >&2; exit 64; }
  GEMINI_ENV=()
  CALLER_TALK=(--pcm "${LAB_CALLER_PCM}" --talk-after-secs "${LAB_TALK_AFTER_S:-6}" --listen-secs "${LAB_LISTEN_S:-45}")
fi

# ── the seat: stub agent under the buzz-acp being tested ─────────────────────
cat > "${RUN_DIR}/seat-rules.toml" <<TOML
[[rules]]
name = "addressed"
channels = "all"
kinds = [9]
require_mention = true
prompt_tag = "addressed"

[[rules]]
name = "caller-anywhere"
channels = "all"
kinds = [9]
require_mention = false
filter = 'author == "${CALLER_PUB}"'
prompt_tag = "front-door"
TOML
NONCE="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
echo "${NONCE}" > "${RUN_DIR}/nonce"
env -i HOME="${HOME}" USER="${USER}" PATH="$(dirname "${BUZZ_BIN}"):/usr/bin:/bin" NO_COLOR=1 \
  BUZZ_RELAY_URL="${RELAY_URL}" \
  BUZZ_PRIVATE_KEY="$(sed -n 's/^BUZZ_PRIVATE_KEY=//p' "${STATE}/keys/seat.env")" \
  BUZZ_ACP_AGENT_COMMAND="${HERE}/stub_seat_agent.py" BUZZ_ACP_MCP_COMMAND="" \
  BUZZ_ACP_NO_MEMORY=true BUZZ_ACP_SUBSCRIBE=config BUZZ_ACP_CONFIG="${RUN_DIR}/seat-rules.toml" \
  BUZZ_ACP_RESPOND_TO=owner-only BUZZ_ACP_AGENT_OWNER="${CALLER_PUB}" \
  BUZZ_ACP_SESSION_POLICY=thread BUZZ_ACP_SELF_WAKE_TAG=voice-bridge=ask \
  BUZZ_ACP_TURN_LOG_DIR="${RUN_DIR}/turnlog" \
  STUB_SEAT_LOG="${RUN_DIR}/seat-prompts.jsonl" STUB_SEAT_NONCE="${NONCE}" \
  RUST_LOG=buzz_acp=info \
  "${ACP_BIN}" >"${RUN_DIR}/seat.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 60); do grep -q "subscribed to channel" "${RUN_DIR}/seat.log" && break; sleep 1; done
grep -q "subscribed to channel" "${RUN_DIR}/seat.log" || { log "seat did not subscribe"; exit 70; }

# ── the bridge, reading the seat's own env file ──────────────────────────────
# A closed port for the gemini_connect fault: nothing listens on GEMINI_PORT+1.
if [[ "${LAB_FAULT}" == "gemini_connect" ]]; then
  GEMINI_ENV=(VOICE_BRIDGE_GEMINI_URL="ws://127.0.0.1:$((GEMINI_PORT + 1))" GEMINI_API_KEY=lab-key)
fi
BRIDGE_STARTS=0
start_bridge() {  # waits for this start's own "watching for huddles"
  BRIDGE_STARTS=$((BRIDGE_STARTS + 1))
  env -i HOME="${HOME}" PATH=/usr/bin:/bin \
    BUZZ_RELAY_URL="${RELAY_URL}" VOICE_BRIDGE_KEY_FILE="${STATE}/keys/seat.env" \
    VOICE_BRIDGE_PARENT_CHANNELS="${DM}" VOICE_BRIDGE_STARTERS="${CALLER_PUB}" \
    "${GEMINI_ENV[@]}" \
    VOICE_BRIDGE_LOG_DIR="${RUN_DIR}/bridge-calls" VOICE_BRIDGE_ASK_TIMEOUT_SECS=60 \
    VOICE_BRIDGE_HEARTBEAT_SECS="${LAB_HEARTBEAT_S:-5}" \
    VOICE_BRIDGE_TRACE_FRAMES="${LAB_TRACE_FRAMES:-0}" \
    RUST_LOG=buzz_voice_bridge=info,buzz_ws_client=info,tungstenite=info \
    "${BRIDGE_BIN}" >>"${RUN_DIR}/bridge.log" 2>&1 &
  BRIDGE_PID=$!
  PIDS+=("${BRIDGE_PID}")
  for _ in $(seq 1 30); do
    [[ "$(grep -c "watching for huddles" "${RUN_DIR}/bridge.log")" -ge "${BRIDGE_STARTS}" ]] && return 0
    sleep 1
  done
  log "bridge start ${BRIDGE_STARTS} never reached the relay"
  exit 70
}
start_bridge

# ── the call, shaped like the phone's ────────────────────────────────────────
EPH="$(as caller --format compact channels create --name "huddle-lab" --type stream --visibility private --ttl 3600 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["channel_id"])')"
echo "${EPH}" > "${RUN_DIR}/ephemeral"
announce() {  # the caller's kind:48100 / 48103, signed and posted as the phone does
  "${CALLER_BIN}" --relay "${RELAY_URL}" --key-file "${STATE}/keys/caller.env" \
    --channel "${EPH}" --parent "${DM}" --announce "$1" >>"${RUN_DIR}/lab.log"
}
if [[ "${LAB_FAULT}" == "room_join" ]]; then
  # The relay refuses a kind:48100 whose backing channel does not exist, so
  # the huddle has to be announced while the channel is still there. Stop the
  # watcher, announce, delete the channel, start the watcher again: it picks
  # the huddle up from the subscription's 30 s backfill and finds no room.
  kill -TERM "${BRIDGE_PID}" 2>/dev/null || true
  for _ in $(seq 1 20); do kill -0 "${BRIDGE_PID}" 2>/dev/null || break; sleep 0.5; done
  announce 48100
  as caller --format compact channels delete --channel "${EPH}" >>"${RUN_DIR}/lab.log"
  log "room_join fault: huddle ${EPH} announced, backing channel deleted"
  start_bridge
  # The join retries take 1+2+4+8+8 s; let the bridge exhaust them.
  sleep 35
else
  announce 48100
  log "huddle ${EPH} started in ${DM}"
  sleep "${LAB_CALLER_DELAY_S:-3}"
  if [[ "${LAB_FAULT}" == "mid_call" || "${LAB_FAULT}" == "relay_gone" ]]; then
    ( sleep "${LAB_FAULT_AFTER_S:-6}"
      case "${LAB_FAULT}" in
        mid_call)   kill -KILL "${FAKE_GEMINI_PID:-0}" 2>/dev/null || true ;;
        relay_gone) kill -KILL "${RELAY_PID}" 2>/dev/null || true ;;
      esac
      echo "fault ${LAB_FAULT} fired" >> "${RUN_DIR}/lab.log" ) &
  fi
  "${CALLER_BIN}" --relay "${RELAY_URL}" --key-file "${STATE}/keys/caller.env" \
    --channel "${EPH}" --parent "${DM}" "${CALLER_TALK[@]}" --save-received "${RUN_DIR}/heard_48k.raw" \
    > "${RUN_DIR}/caller.json" 2>"${RUN_DIR}/caller.log" || log "caller exited $?"
  log "caller hung up: $(cat "${RUN_DIR}/caller.json" 2>/dev/null)"
fi
sleep 4
if [[ "${LAB_FAULT}" != "relay_gone" ]]; then
  announce 48103
fi
sleep 3

if [[ "${LAB_FAULT}" != "relay_gone" ]]; then
  as caller messages get --channel "${EPH}" --limit 50 > "${RUN_DIR}/ephemeral-messages.json" || true
  as caller messages get --channel "${DM}" --limit 50 > "${RUN_DIR}/dm-messages.json" || true
fi

# bridge.jsonl must survive a restart and show it: stop, start, stop.
kill -TERM "${BRIDGE_PID}" 2>/dev/null || true
for _ in $(seq 1 20); do kill -0 "${BRIDGE_PID}" 2>/dev/null || break; sleep 0.5; done
if [[ "${LAB_FAULT}" != "relay_gone" ]]; then
  start_bridge
  sleep "${LAB_RESTART_WATCH_S:-8}"
  kill -TERM "${BRIDGE_PID}" 2>/dev/null || true
  sleep 2
fi

python3 "${HERE}/lab_check.py" --run-dir "${RUN_DIR}" --seat "${SEAT_PUB}" --caller "${CALLER_PUB}" \
  --fault "${LAB_FAULT}" --results "${STATE}/results.jsonl"

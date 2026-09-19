#!/usr/bin/env bash
# aitaco relay lane: move buzz.aitaco.co to a pinned image digest, with a
# backup before and an automatic rollback if the relay does not come back.
# Runs on hip and drives the GCE host over `gcloud compute ssh`.
# Runbook: docs/aitaco/RELAY_LANE.md.
#
#   scripts/aitaco/relay-deploy.sh plan   <image@sha256:…>
#       Read-only. Live digest and revision, target revision, and the commits
#       and migrations between them.
#   scripts/aitaco/relay-deploy.sh carry  <image@sha256:…>
#       Plan, then copy the image from GHCR onto the host through hip, so the
#       host needs no registry credential. Changes nothing that runs.
#   scripts/aitaco/relay-deploy.sh deploy <image@sha256:…> --canary-channel <uuid>
#       [--allow-migrations]
#       Carry, backup, save the relay logs, pin, start, then check the running
#       image and revision, NIP-11 and a canary post. Any failure or interrupt
#       after the pin restores the previous .env and starts the previous digest
#       again, then verifies that it runs. A run that applied migrations is never
#       rolled back by digest.
set -euo pipefail

die() { echo "relay-deploy: $*" >&2; exit 1; }

CMD="${1:-}"
TARGET="${2:-}"
[[ "$CMD" == "plan" || "$CMD" == "carry" || "$CMD" == "deploy" ]] || die "usage: $0 plan|carry|deploy <image@sha256:…> [--canary-channel <uuid>] [--allow-migrations]"
shift 2 || true
CANARY_CHANNEL=""
ALLOW_MIGRATIONS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --canary-channel) CANARY_CHANNEL="${2:?}"; shift 2 ;;
    --allow-migrations) ALLOW_MIGRATIONS=1; shift ;;
    *) die "unknown flag: $1" ;;
  esac
done

HOST="${RELAY_HOST:-buzz-relay}"
ZONE="${RELAY_ZONE:-us-central1-a}"
PUBLIC_URL="${RELAY_PUBLIC_URL:-https://buzz.aitaco.co}"
REPO_URL="https://github.com/aitaco-llc/buzz.git"
BACKUP_BUCKET="gs://aitaco-buzz-backups"
MIGRATION_DIRS=(migrations crates/buzz-push-gateway/migrations)
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${RELAY_DEPLOY_STATE:-${HOME}/.local/state/buzz-relay-deploys}/${STAMP}-${CMD}"
mkdir -p "$LOG_DIR"

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "${LOG_DIR}/deploy.log" >&2; }
remote() { gcloud compute ssh "$HOST" --zone "$ZONE" --command "$1" < /dev/null; }
for tool in gcloud git curl jq buzz; do command -v "$tool" >/dev/null || die "missing tool: $tool"; done
# Git pathspecs below are relative; run from the repository root.
cd "$(git rev-parse --show-toplevel)" || die "run this inside a clone of aitaco-llc/buzz"

# Only the relay image. Its debug variant and the push gateway share the same
# revision label, so the digest (checked again on the running container) is
# what pins the right image.
RELAY_REPO="${RELAY_IMAGE_REPO:-aitaco-llc/buzz}"
[[ "$TARGET" =~ ^ghcr\.io/([a-z0-9._/-]+)@(sha256:[0-9a-f]{64})$ ]] \
  || die "target must be a digest-pinned GHCR image, ghcr.io/<repo>@sha256:<64 hex>"
TARGET_REPO="${BASH_REMATCH[1]}"
TARGET_DIGEST="${BASH_REMATCH[2]}"
[[ "$TARGET_REPO" == "$RELAY_REPO" ]] || die "target repo is ${TARGET_REPO}; only ghcr.io/${RELAY_REPO} is deployed here"

MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
# Pull token for one GHCR repository. GHCR_TOKEN (read:packages) is needed for
# private images. It is only ever used from hip.
registry_token() {
  if [[ -n "${GHCR_TOKEN:-}" ]]; then
    curl -fsS -u "x:${GHCR_TOKEN}" "https://ghcr.io/token?scope=repository:$1:pull" | jq -r .token
  else
    curl -fsS "https://ghcr.io/token?scope=repository:$1:pull" | jq -r .token
  fi
}

# Revision label of a GHCR image, read from the registry without pulling. The
# host is linux/amd64.
image_revision() {
  local repo="$1" digest="$2" token manifest accept="$MANIFEST_ACCEPT"
  token="$(registry_token "$repo")"
  manifest="$(curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
    "https://ghcr.io/v2/${repo}/manifests/${digest}")"
  if jq -e '.manifests' <<<"$manifest" >/dev/null; then
    digest="$(jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' <<<"$manifest" | head -1)"
    [[ -n "$digest" ]] || return 1
    manifest="$(curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: ${accept}" \
      "https://ghcr.io/v2/${repo}/manifests/${digest}")"
  fi
  curl -fsSL -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${repo}/blobs/$(jq -r .config.digest <<<"$manifest")" \
    | jq -r '.config.Labels["org.opencontainers.image.revision"] // empty'
}

# ── plan ─────────────────────────────────────────────────────────────────────
# Prints two lines per container: its image ref, then its revision label.
running() { remote 'for c in buzz-prod-relay-1 buzz-prod-pair-relay-1; do sudo docker inspect -f "{{.Config.Image}}
{{index .Config.Labels \"org.opencontainers.image.revision\"}}" "$c"; done'; }
LIVE_IMAGE="$(remote 'sudo grep -E "^BUZZ_IMAGE=" /opt/buzz/.env | cut -d= -f2-')"
LIVE_RUNNING="$(running)"
LIVE_REV="$(sed -n 2p <<<"$LIVE_RUNNING")"
[[ -n "$LIVE_IMAGE" && -n "$LIVE_REV" ]] || die "could not read the live image and revision"
# .env and the containers must agree, or rollback would restore an image that never ran.
[[ "$(sed -n '1p;3p' <<<"$LIVE_RUNNING" | sort -u)" == "$LIVE_IMAGE" ]] \
  || die "drift: /opt/buzz/.env names ${LIVE_IMAGE} but the containers run $(sed -n '1p;3p' <<<"$LIVE_RUNNING" | sort -u | tr '\n' ' '). Settle that by hand first."
TARGET_REV="$(image_revision "$TARGET_REPO" "$TARGET_DIGEST")" \
  || die "could not read ${TARGET} from the registry (private package? set GHCR_TOKEN)"
[[ -n "$TARGET_REV" ]] || die "${TARGET} carries no org.opencontainers.image.revision label"

git fetch --quiet "$REPO_URL" main
git cat-file -e "${TARGET_REV}^{commit}" 2>/dev/null || die "target revision ${TARGET_REV} is not in this repository"
git merge-base --is-ancestor "$TARGET_REV" FETCH_HEAD || die "target revision ${TARGET_REV} is not on aitaco-llc/buzz main"
git cat-file -e "${LIVE_REV}^{commit}" 2>/dev/null || die "live revision ${LIVE_REV} is not in this repository"
COMMITS="$(git rev-list --count "${LIVE_REV}..${TARGET_REV}")"
BEHIND="$(git rev-list --count "${TARGET_REV}..${LIVE_REV}")"
MIGRATIONS="$(git diff --name-status "$LIVE_REV" "$TARGET_REV" -- "${MIGRATION_DIRS[@]}")"

{
  echo "live:    ${LIVE_IMAGE}"
  echo "         revision ${LIVE_REV}"
  echo "target:  ${TARGET}"
  echo "         revision ${TARGET_REV}"
  echo "commits: ${COMMITS} ahead of live, ${BEHIND} behind"
  echo "migrations between them:"
  if [[ -n "$MIGRATIONS" ]]; then sed 's/^/  /' <<<"$MIGRATIONS"; else echo "  none"; fi
} | tee "${LOG_DIR}/plan.txt"
[[ "$BEHIND" == "0" ]] || log "warning: the target lacks ${BEHIND} commit(s) the live relay has"

if [[ "$CMD" == "plan" ]]; then
  echo "Plan only; nothing changed. Log: ${LOG_DIR}"
  exit 0
fi

# ── deploy preconditions ────────────────────────────────────────────────────
if [[ "$CMD" == "deploy" ]]; then
  [[ -n "$CANARY_CHANNEL" ]] || die "deploy needs --canary-channel <uuid>"
  # The canary talks to the relay being deployed, not whatever BUZZ_RELAY_URL says.
  canary_buzz() { BUZZ_RELAY_URL="$PUBLIC_URL" buzz --format compact "$@"; }
  canary_buzz messages get --channel "$CANARY_CHANNEL" --limit 1 >/dev/null \
    || die "cannot read canary channel ${CANARY_CHANNEL} on ${PUBLIC_URL} with this identity; nothing changed"
  [[ "$LIVE_IMAGE" != "$TARGET" ]] || die "the live relay already runs ${TARGET}"
  if [[ -n "$MIGRATIONS" && "$ALLOW_MIGRATIONS" != "1" ]]; then
    die "the target adds migrations; rollback would then need a database restore, not a digest swap. Re-run with --allow-migrations once that is accepted."
  fi
fi

# ── carry ────────────────────────────────────────────────────────────────────
# The GHCR packages are private, and buzz-relay holds no registry credential.
# hip reads the image with GHCR_TOKEN, writes it as an OCI layout (every
# platform, every blob checked against its digest) and streams it into the
# host's `docker load`. The host's Docker uses the containerd image store, which
# keeps the index digest and the name below, so BUZZ_IMAGE stays pinned by
# digest and compose finds the image locally instead of pulling it.
host_has_target() {
  [[ "$(remote "sudo docker image inspect -f '{{.Id}}' ${TARGET} 2>/dev/null" || true)" == "$TARGET_DIGEST" ]]
}
carry_image() {
  local dir token top child blob
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064 # expand $dir now; it is local
  trap "rm -rf '${dir}'; trap - RETURN" RETURN
  mkdir -p "${dir}/blobs/sha256"
  token="$(registry_token "$TARGET_REPO")"
  # fetch <digest> manifest|blob: store under blobs/ and check the digest.
  fetch() {
    local out="${dir}/blobs/sha256/${1#sha256:}" path=blobs
    [[ -s "$out" ]] && return 0
    [[ "$2" == manifest ]] && path=manifests
    curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: ${MANIFEST_ACCEPT}" \
      "https://ghcr.io/v2/${TARGET_REPO}/${path}/$1" -o "$out" || return 1
    [[ "sha256:$(sha256sum "$out" | cut -d' ' -f1)" == "$1" ]] || { echo "digest mismatch: $1" >&2; return 1; }
  }
  # fetch_image <manifest digest>: the manifest, its config and its layers.
  fetch_image() {
    local m="${dir}/blobs/sha256/${1#sha256:}"
    fetch "$1" manifest || return 1
    for blob in $(jq -r '.config.digest, .layers[].digest' "$m"); do fetch "$blob" blob || return 1; done
  }
  fetch "$TARGET_DIGEST" manifest || return 1
  top="${dir}/blobs/sha256/${TARGET_DIGEST#sha256:}"
  if jq -e '.manifests' "$top" >/dev/null; then
    for child in $(jq -r '.manifests[].digest' "$top"); do fetch_image "$child" || return 1; done
  else
    fetch_image "$TARGET_DIGEST" || return 1
  fi
  printf '{"imageLayoutVersion":"1.0.0"}' > "${dir}/oci-layout"
  jq -n --arg mt "$(jq -r .mediaType "$top")" --arg d "$TARGET_DIGEST" \
    --argjson size "$(stat -c %s "$top")" --arg name "$TARGET" \
    '{schemaVersion:2, mediaType:"application/vnd.oci.image.index.v1+json",
      manifests:[{mediaType:$mt, digest:$d, size:$size,
                  annotations:{"io.containerd.image.name":$name}}]}' > "${dir}/index.json"
  log "carry: $(du -sh "$dir" | cut -f1) in $(find "${dir}/blobs" -type f | wc -l) blobs, streaming to ${HOST}"
  tar -C "$dir" -cf - oci-layout index.json blobs \
    | gcloud compute ssh "$HOST" --zone "$ZONE" --command "sudo docker load" >&2 || return 1
  host_has_target
}

if host_has_target; then
  log "carry: ${HOST} already has ${TARGET}"
else
  carry_image || die "could not carry ${TARGET} to ${HOST}; nothing that runs has changed"
  log "carry: ${HOST} has ${TARGET}"
fi
if [[ "$CMD" == "carry" ]]; then
  echo "Carried; nothing that runs has changed. Log: ${LOG_DIR}"
  exit 0
fi

# ── deploy ───────────────────────────────────────────────────────────────────
log "backup: /opt/buzz/backup.sh to ${BACKUP_BUCKET}, and .env to .env.pre-${STAMP}"
remote "sudo cp -p /opt/buzz/.env /opt/buzz/.env.pre-${STAMP} && sudo /opt/buzz/backup.sh" \
  || die "backup failed; nothing changed"
BACKUP="$(gcloud storage ls "${BACKUP_BUCKET}/" | sed -n 's#.*/\([0-9]\{8\}T[0-9]\{6\}Z\)/$#\1#p' | sort | tail -1)"
[[ -n "$BACKUP" && ! "$BACKUP" < "$STAMP" ]] || die "no backup from this run in ${BACKUP_BUCKET}; nothing changed"
log "backup: ${BACKUP_BUCKET}/${BACKUP}/"

# Removing a container deletes its json-file log, and that log holds the only
# record of which pubkey each conn_id was (the NIP-42 auth lines). Keep a copy
# of each container's log on the host before anything recreates it.
save_logs() {
  remote "set -eo pipefail; for c in buzz-prod-relay-1 buzz-prod-pair-relay-1; do f=/var/tmp/\$c-\$(sudo docker inspect -f '{{.Id}}' \$c | cut -c1-12)-${STAMP}-$1.log.gz; sudo docker logs \$c 2>&1 | gzip | sudo tee \$f >/dev/null; echo \$f; done"
}

STARTED=0
rollback() {
  trap - INT TERM HUP
  local reason="$1"
  if [[ "$STARTED" == "1" && -n "$MIGRATIONS" ]]; then
    # The new relay may have applied migrations (BUZZ_AUTO_MIGRATE), and the
    # old binary refuses to start on a schema it does not know. Leave it up.
    log "FAILED after start with migrations (${reason}). Not rolling back by digest."
    log "Recovery: restore ${BACKUP_BUCKET}/${BACKUP}/ with /opt/buzz/.env.pre-${STAMP} (see backup.sh)."
    remote "echo '${STAMP} ${LIVE_IMAGE} -> ${TARGET} (${TARGET_REV}) FAILED (${reason}), not rolled back, backup=${BACKUP}' | sudo tee -a /opt/buzz/deploys.log >/dev/null" || true
    die "deploy failed at: ${reason}. NOT rolled back (migrations). Log: ${LOG_DIR}"
  fi
  log "ROLLBACK (${reason}): restoring .env.pre-${STAMP} (${LIVE_IMAGE}) and starting it"
  local ok=1
  save_logs rollback >&2 || log "warning: could not save the relay logs before rollback"
  remote "sudo cp -p /opt/buzz/.env.pre-${STAMP} /opt/buzz/.env && sudo /opt/buzz/buzzctl start" || ok=0
  # Verify, don't assume: .env and both containers must be back on the live image.
  [[ "$(remote 'sudo grep -E "^BUZZ_IMAGE=" /opt/buzz/.env | cut -d= -f2-' || true)" == "$LIVE_IMAGE" ]] || ok=0
  [[ "$(running 2>/dev/null || true)" == "$LIVE_RUNNING" ]] || ok=0
  curl -fsS -m 10 -H 'Accept: application/nostr+json' "$PUBLIC_URL" | jq -e .name >/dev/null || ok=0
  if [[ "$ok" == "1" ]]; then
    remote "echo '${STAMP} ${LIVE_IMAGE} -> ${TARGET} (${TARGET_REV}) ROLLED BACK (${reason}) backup=${BACKUP}' | sudo tee -a /opt/buzz/deploys.log >/dev/null" || true
    die "deploy failed at: ${reason}. Rolled back and verified: ${LIVE_IMAGE} runs, NIP-11 answers. Log: ${LOG_DIR}"
  fi
  die "deploy failed at: ${reason}. ROLLBACK DID NOT VERIFY: check /opt/buzz/.env (.env.pre-${STAMP} is the previous one) and the containers by hand NOW. Log: ${LOG_DIR}"
}

log "logs: saving the relay and pair-relay logs on ${HOST}"
save_logs deploy >&2 || die "could not save the relay logs; nothing that runs has changed"

trap 'rollback "interrupted"' INT TERM HUP
log "pin BUZZ_IMAGE=${TARGET}"
remote "sudo sed -i 's#^BUZZ_IMAGE=.*#BUZZ_IMAGE=${TARGET}#' /opt/buzz/.env && sudo grep -qx 'BUZZ_IMAGE=${TARGET}' /opt/buzz/.env" \
  || rollback "pin"

log "start: buzzctl start (compose up -d --wait)"
STARTED=1
remote "sudo /opt/buzz/buzzctl start" || rollback "start"

NOW_RUNNING="$(running)" || rollback "inspect"
[[ "$NOW_RUNNING" == "$(printf '%s\n%s\n%s\n%s' "$TARGET" "$TARGET_REV" "$TARGET" "$TARGET_REV")" ]] \
  || rollback "containers run '${NOW_RUNNING//$'\n'/ }', expected ${TARGET} at ${TARGET_REV}"
log "running: relay and pair-relay on ${TARGET} (${TARGET_REV})"

nip11_ok=0
for _ in 1 2 3 4 5 6; do
  if curl -fsS -m 10 -H 'Accept: application/nostr+json' "$PUBLIC_URL" | jq -e .name >/dev/null; then nip11_ok=1; break; fi
  sleep 5
done
[[ "$nip11_ok" == "1" ]] || rollback "NIP-11"
log "NIP-11: ${PUBLIC_URL} answers"

CANARY_TEXT="relay deploy canary ${STAMP}: ${TARGET_REV}"
CANARY_ID="$(canary_buzz messages send --channel "$CANARY_CHANNEL" --content "$CANARY_TEXT" | jq -r .event_id)" \
  || rollback "canary send"
[[ "$CANARY_ID" =~ ^[0-9a-f]{64}$ ]] || rollback "canary send returned no event id"
canary_ok=0
for _ in 1 2 3 4 5 6; do
  if canary_buzz messages get --channel "$CANARY_CHANNEL" --limit 20 \
      | jq -e --arg id "$CANARY_ID" 'any(.[]; .id == $id)' >/dev/null; then canary_ok=1; break; fi
  sleep 5
done
[[ "$canary_ok" == "1" ]] || rollback "canary read-back"
log "canary: ${CANARY_ID} posted and read back"

trap - INT TERM HUP
remote "echo '${STAMP} ${LIVE_IMAGE} -> ${TARGET} (${TARGET_REV}) ok backup=${BACKUP} canary=${CANARY_ID}' | sudo tee -a /opt/buzz/deploys.log >/dev/null" \
  || log "warning: could not append to /opt/buzz/deploys.log"
log "DONE: ${HOST} runs ${TARGET} (${TARGET_REV}). Previous .env kept as /opt/buzz/.env.pre-${STAMP}. Log: ${LOG_DIR}"

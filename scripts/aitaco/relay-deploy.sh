#!/usr/bin/env bash
# aitaco relay lane: move buzz.aitaco.co to a pinned image digest, with a
# backup before and an automatic rollback if the relay does not come back.
# Runs on hip and drives the GCE host over `gcloud compute ssh`.
# Runbook: docs/aitaco/RELAY_LANE.md.
#
#   scripts/aitaco/relay-deploy.sh plan   <image@sha256:…>
#       Read-only. Live digest and revision, target revision, and the commits
#       and migrations between them.
#   scripts/aitaco/relay-deploy.sh deploy <image@sha256:…> --canary-channel <uuid>
#       [--allow-migrations]
#       Backup, pull, pin, start, then check the running revision, NIP-11 and a
#       canary post. Any failure after the pin restores the previous .env and
#       starts the previous digest again.
set -euo pipefail

die() { echo "relay-deploy: $*" >&2; exit 1; }

CMD="${1:-}"
TARGET="${2:-}"
[[ "$CMD" == "plan" || "$CMD" == "deploy" ]] || die "usage: $0 plan|deploy <image@sha256:…> [--canary-channel <uuid>] [--allow-migrations]"
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

[[ "$TARGET" =~ ^ghcr\.io/([a-z0-9._/-]+)@(sha256:[0-9a-f]{64})$ ]] \
  || die "target must be a digest-pinned GHCR image, ghcr.io/<repo>@sha256:<64 hex>"
TARGET_REPO="${BASH_REMATCH[1]}"
TARGET_DIGEST="${BASH_REMATCH[2]}"

# Revision label of a GHCR image, read from the registry without pulling. The
# host is linux/amd64. GHCR_TOKEN (read:packages) is needed for private images.
image_revision() {
  local repo="$1" digest="$2" token manifest accept
  if [[ -n "${GHCR_TOKEN:-}" ]]; then
    token="$(curl -fsS -u "x:${GHCR_TOKEN}" "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r .token)"
  else
    token="$(curl -fsS "https://ghcr.io/token?scope=repository:${repo}:pull" | jq -r .token)"
  fi
  accept='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'
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
LIVE="$(remote 'sudo grep -E "^BUZZ_IMAGE=" /opt/buzz/.env | cut -d= -f2-; sudo docker inspect -f "{{index .Config.Labels \"org.opencontainers.image.revision\"}}" buzz-prod-relay-1')"
LIVE_IMAGE="$(sed -n 1p <<<"$LIVE")"
LIVE_REV="$(sed -n 2p <<<"$LIVE")"
[[ -n "$LIVE_IMAGE" && -n "$LIVE_REV" ]] || die "could not read the live image and revision"
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

# ── deploy ───────────────────────────────────────────────────────────────────
[[ -n "$CANARY_CHANNEL" ]] || die "deploy needs --canary-channel <uuid>"
[[ "$LIVE_IMAGE" != "$TARGET" ]] || die "the live relay already runs ${TARGET}"
if [[ -n "$MIGRATIONS" && "$ALLOW_MIGRATIONS" != "1" ]]; then
  die "the target adds migrations; rollback would then need a database restore, not a digest swap. Re-run with --allow-migrations once that is accepted."
fi

log "backup: /opt/buzz/backup.sh to ${BACKUP_BUCKET}, and .env to .env.pre-${STAMP}"
remote "sudo cp -p /opt/buzz/.env /opt/buzz/.env.pre-${STAMP} && sudo /opt/buzz/backup.sh" \
  || die "backup failed; nothing changed"
BACKUP="$(gcloud storage ls "${BACKUP_BUCKET}/" | sed -n 's#.*/\([0-9]\{8\}T[0-9]\{6\}Z\)/$#\1#p' | sort | tail -1)"
[[ -n "$BACKUP" && ! "$BACKUP" < "$STAMP" ]] || die "no backup from this run in ${BACKUP_BUCKET}; nothing changed"
log "backup: ${BACKUP_BUCKET}/${BACKUP}/"

log "pull ${TARGET} on ${HOST}"
remote "sudo docker pull ${TARGET} >/dev/null" || die "pull failed; nothing changed"

rollback() {
  log "ROLLBACK: restoring .env.pre-${STAMP} (${LIVE_IMAGE}) and starting it"
  remote "sudo cp -p /opt/buzz/.env.pre-${STAMP} /opt/buzz/.env && sudo /opt/buzz/buzzctl start" || true
  if curl -fsS -m 10 -H 'Accept: application/nostr+json' "$PUBLIC_URL" | jq -e .name >/dev/null; then
    log "ROLLBACK: NIP-11 answers again on ${LIVE_IMAGE}"
  else
    log "ROLLBACK: NIP-11 still failing; the relay needs a human now"
  fi
  remote "echo '${STAMP} ${LIVE_IMAGE} -> ${TARGET} (${TARGET_REV}) ROLLED BACK backup=${BACKUP}' | sudo tee -a /opt/buzz/deploys.log >/dev/null" || true
  die "deploy failed at: $1. Rolled back. Log: ${LOG_DIR}"
}

log "pin BUZZ_IMAGE=${TARGET}"
remote "sudo sed -i 's#^BUZZ_IMAGE=.*#BUZZ_IMAGE=${TARGET}#' /opt/buzz/.env && sudo grep -qx 'BUZZ_IMAGE=${TARGET}' /opt/buzz/.env" \
  || rollback "pin"

log "start: buzzctl start (compose up -d --wait)"
remote "sudo /opt/buzz/buzzctl start" || rollback "start"

RUNNING_REV="$(remote 'sudo docker inspect -f "{{index .Config.Labels \"org.opencontainers.image.revision\"}}" buzz-prod-relay-1 buzz-prod-pair-relay-1' | sort -u)" \
  || rollback "inspect"
[[ "$RUNNING_REV" == "$TARGET_REV" ]] || rollback "running revision is '${RUNNING_REV//$'\n'/ }', expected ${TARGET_REV}"
log "running: relay and pair-relay at ${TARGET_REV}"

nip11_ok=0
for _ in 1 2 3 4 5 6; do
  if curl -fsS -m 10 -H 'Accept: application/nostr+json' "$PUBLIC_URL" | jq -e .name >/dev/null; then nip11_ok=1; break; fi
  sleep 5
done
[[ "$nip11_ok" == "1" ]] || rollback "NIP-11"
log "NIP-11: ${PUBLIC_URL} answers"

CANARY_TEXT="relay deploy canary ${STAMP}: ${TARGET_REV}"
CANARY_ID="$(buzz --format compact messages send --channel "$CANARY_CHANNEL" --content "$CANARY_TEXT" | jq -r .event_id)" \
  || rollback "canary send"
[[ "$CANARY_ID" =~ ^[0-9a-f]{64}$ ]] || rollback "canary send returned no event id"
canary_ok=0
for _ in 1 2 3 4 5 6; do
  if buzz --format compact messages get --channel "$CANARY_CHANNEL" --limit 20 \
      | jq -e --arg id "$CANARY_ID" 'any(.[]; .id == $id)' >/dev/null; then canary_ok=1; break; fi
  sleep 5
done
[[ "$canary_ok" == "1" ]] || rollback "canary read-back"
log "canary: ${CANARY_ID} posted and read back"

remote "echo '${STAMP} ${LIVE_IMAGE} -> ${TARGET} (${TARGET_REV}) ok backup=${BACKUP} canary=${CANARY_ID}' | sudo tee -a /opt/buzz/deploys.log >/dev/null"
log "DONE: ${HOST} runs ${TARGET} (${TARGET_REV}). Previous .env kept as /opt/buzz/.env.pre-${STAMP}. Log: ${LOG_DIR}"

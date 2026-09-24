#!/usr/bin/env bash
# Install one voice bridge per seat as a per-user launchd job: the macOS
# counterpart of buzz-voice-bridge@.service. Each seat gets its own voice in
# Lloyd's DM huddles with it; see README.md.
#
#   scripts/aitaco/voice-bridge/install-launchd.sh collins woody jessie
#   scripts/aitaco/voice-bridge/install-launchd.sh --remove collins
#
# Needs ~/.local/bin/buzz-voice-bridge, and for each seat its key file
# (~/.config/buzz-agents/<seat>.env) and persona
# (~/.local/share/aitaco-agents/personas/<seat>.md). The Gemini key is fetched
# by the binary's default gcloud command, so gcloud must be logged in.
# bash 3.2-safe.
set -euo pipefail

REMOVE=0
if [[ "${1:-}" == "--remove" ]]; then REMOVE=1; shift; fi
(( $# )) || { echo "usage: $0 [--remove] <seat>..." >&2; exit 2; }

BIN="${HOME}/.local/bin/buzz-voice-bridge"
AGENTS="${HOME}/Library/LaunchAgents"
LOGS="${HOME}/Library/Logs/buzz-voice-bridge"
STARTERS="${VOICE_BRIDGE_STARTERS:-0f8471300f7806058507999b06f16805168c640aad3ffa5474cf8ec9e7c6a0ca}"
RELAY="${BUZZ_RELAY_URL:-wss://buzz.aitaco.co}"
GCLOUD_DIR="$(dirname "$(command -v gcloud || echo /opt/homebrew/bin/gcloud)")"
UID_N="$(id -u)"

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

for seat in "$@"; do
  [[ "${seat}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || { echo "bad seat name: ${seat}" >&2; exit 2; }
  label="co.aitaco.voice-bridge.${seat}"
  plist="${AGENTS}/${label}.plist"
  launchctl bootout "gui/${UID_N}/${label}" 2>/dev/null || true
  if (( REMOVE )); then
    rm -f "${plist}"
    echo "removed ${label}"
    continue
  fi
  key="${HOME}/.config/buzz-agents/${seat}.env"
  persona="${HOME}/.local/share/aitaco-agents/personas/${seat}.md"
  [[ -x "${BIN}" ]] || { echo "missing ${BIN}" >&2; exit 1; }
  [[ -f "${key}" ]] || { echo "${seat}: no key file ${key}" >&2; exit 1; }
  [[ -f "${persona}" ]] || echo "${seat}: no persona at ${persona}; the voice will have its name only" >&2
  mkdir -p "${AGENTS}" "${LOGS}" "${HOME}/.local/state/buzz-voice-bridge/${seat}"
  env_entries=""
  add() { env_entries="${env_entries}      <key>$1</key><string>$(xml "$2")</string>
"; }
  add BUZZ_RELAY_URL "${RELAY}"
  add VOICE_BRIDGE_KEY_FILE "${key}"
  add VOICE_BRIDGE_PERSONA_FILE "${persona}"
  add VOICE_BRIDGE_STARTERS "${STARTERS}"
  add VOICE_BRIDGE_LOG_DIR "${HOME}/.local/state/buzz-voice-bridge/${seat}"
  add VOICE_BRIDGE_RETENTION_DAYS "30"
  add HOME "${HOME}"
  add PATH "${GCLOUD_DIR}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  add RUST_LOG "buzz_voice_bridge=info,buzz_ws_client=info,tokio_tungstenite=info,tungstenite=info"
  [[ -f "${HOME}/.buzz/GUIDES/AGENT_ROSTER.md" ]] && add VOICE_BRIDGE_CONTEXT_FILES "${HOME}/.buzz/GUIDES/AGENT_ROSTER.md"
  # Per-seat overrides, as the systemd unit's EnvironmentFile: KEY=VALUE lines.
  overrides="${HOME}/.config/aitaco/voice-bridge/${seat}.env"
  if [[ -f "${overrides}" ]]; then
    while IFS='=' read -r k v; do
      [[ -z "${k}" || "${k}" == \#* ]] && continue
      add "${k}" "${v}"
    done < "${overrides}"
  fi
  cat > "${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${label}</string>
  <key>ProgramArguments</key>
  <array><string>${BIN}</string></array>
  <key>EnvironmentVariables</key>
  <dict>
${env_entries}  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>${LOGS}/${seat}.log</string>
  <key>StandardErrorPath</key><string>${LOGS}/${seat}.log</string>
</dict>
</plist>
PLIST
  plutil -lint "${plist}" >/dev/null
  launchctl bootstrap "gui/${UID_N}" "${plist}"
  echo "installed ${label} (log ${LOGS}/${seat}.log)"
done

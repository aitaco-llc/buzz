#!/usr/bin/env bash
# aitaco Desktop lane: build, sign, notarize and (optionally) publish Buzz
# Desktop from aitaco-llc/buzz on a Mac. Runbook: docs/aitaco/DESKTOP_LANE.md.
#
#   scripts/aitaco/desktop-release.sh <X.Y.Z>             build and verify only
#   scripts/aitaco/desktop-release.sh <X.Y.Z> --publish   also tag, release and
#                                                         move the updater feed
#
# Signing, notarization and the updater private key stay on the Mac: they come
# from the environment of the shell that runs this script (see the runbook).
# Tracked files are never edited in a way that survives the run: the version
# patch is reverted on exit, and the release overlay is a generated file.
set -euo pipefail

VERSION="${1:-}"
PUBLISH=0
[[ "${2:-}" == "--publish" ]] && PUBLISH=1

REPO="aitaco-llc/buzz"
REPO_URL="https://github.com/${REPO}.git"
TEAM="${AITACO_APPLE_TEAM:-5F7YLJS4YR}"
IDENTIFIER="co.aitaco.buzz.desktop"
TAG="aitaco-desktop-v${VERSION}"
FEED_TAG="aitaco-desktop-latest"
ENDPOINT="https://github.com/${REPO}/releases/download/${FEED_TAG}/latest.json"
PLATFORM="darwin-aarch64"
# The updater key every installed copy trusts (minisign key id). A build signed
# with any other key, or embedding any other public key, strands installs.
UPDATER_KEY_ID="${AITACO_UPDATER_KEY_ID:-77A198D97C39AD51}"
OUT="${HOME}/.local/state/aitaco-desktop-releases/${VERSION}"

die() { echo "desktop-release: $*" >&2; exit 1; }
# Minisign key id (as minisign prints it) of a base64-encoded minisign file:
# a public key, or a Tauri .sig. Line 2 decodes to 2 algorithm bytes, then the
# 8-byte key id, little-endian.
key_id() {
  python3 -c 'import base64,sys; t=base64.b64decode(sys.argv[1]).decode(); b=base64.b64decode(t.splitlines()[1]); print(b[2:10][::-1].hex().upper())' "$1"
}
# The version latest.json serves; empty only when the feed does not exist (404).
# Any other failure stops the run: a skipped check could move the feed backwards.
feed_version() {
  local body code
  body="$(mktemp)"
  code="$(curl -sSL -o "$body" -w '%{http_code}' "$ENDPOINT")" || { rm -f "$body"; die "cannot reach ${ENDPOINT}"; }
  case "$code" in
    404) rm -f "$body"; echo "" ;;
    200) jq -er '.version' "$body" || { rm -f "$body"; die "${ENDPOINT} has no version"; }; rm -f "$body" ;;
    *) rm -f "$body"; die "${ENDPOINT} answered HTTP ${code}" ;;
  esac
}

# ── preflight ────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || die "run this on an Apple Silicon Mac"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 <X.Y.Z> [--publish]"
cd "$(git rev-parse --show-toplevel)"
for tool in jq gh git curl codesign spctl xcrun python3; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
for var in APPLE_SIGNING_IDENTITY APPLE_API_ISSUER APPLE_API_KEY APPLE_API_KEY_PATH \
           TAURI_SIGNING_PRIVATE_KEY TAURI_SIGNING_PRIVATE_KEY_PASSWORD BUZZ_UPDATER_PUBLIC_KEY; do
  [[ -n "${!var:-}" ]] || die "missing environment variable: $var (see the runbook)"
done
[[ "$APPLE_SIGNING_IDENTITY" == *"(${TEAM})" ]] \
  || die "APPLE_SIGNING_IDENTITY must be a Developer ID for team ${TEAM}"
[[ "$(key_id "$BUZZ_UPDATER_PUBLIC_KEY")" == "$UPDATER_KEY_ID" ]] \
  || die "BUZZ_UPDATER_PUBLIC_KEY is key $(key_id "$BUZZ_UPDATER_PUBLIC_KEY"), expected ${UPDATER_KEY_ID}"
# Untracked files count too: Vite and Tauri read some (.env.production, *.conf.json) on their own.
[[ -z "$(git status --porcelain)" ]] || die "working tree has changes or untracked files"
# Build from a clean BUZZ_* environment, as release.yml does: build.rs bakes
# BUZZ_RELAY_URL, BUZZ_RELAY_HTTP and BUZZ_BUILD_* into the app.
updater_public_key="$BUZZ_UPDATER_PUBLIC_KEY"
while IFS= read -r name; do unset "$name"; done < <(compgen -e | grep '^BUZZ_' || true)
export BUZZ_UPDATER_PUBLIC_KEY="$updater_public_key"

SHA="$(git rev-parse HEAD)"
# Publishing needs a commit on main and a new tag; a build-only run may test a branch.
if [[ "$PUBLISH" == "1" ]]; then
  git fetch --quiet "$REPO_URL" main
  git merge-base --is-ancestor HEAD FETCH_HEAD || die "HEAD is not on ${REPO} main"
  if git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/${TAG}" >/dev/null; then
    die "tag ${TAG} already exists"
  fi
fi
# Versions only go up within this lane. The feed is absent before the first release.
PUBLISHED="$(feed_version)"
if [[ -n "$PUBLISHED" ]]; then
  HIGHEST="$(printf '%s\n%s\n' "$PUBLISHED" "$VERSION" | sort -V | tail -1)"
  [[ "$VERSION" != "$PUBLISHED" && "$HIGHEST" == "$VERSION" ]] \
    || die "version ${VERSION} is not above the published ${PUBLISHED}"
fi
echo "Building Buzz Desktop ${VERSION} (${IDENTIFIER}) at ${SHA}; published: ${PUBLISHED:-none}"

# ── build ────────────────────────────────────────────────────────────────────
restore() {
  git checkout --quiet -- desktop/package.json desktop/src-tauri/tauri.conf.json \
    desktop/src-tauri/Cargo.toml desktop/src-tauri/Cargo.lock
  rm -f desktop/src-tauri/tauri.release.conf.json
}
trap restore EXIT

# shellcheck disable=SC1091
. ./bin/activate-hermit
[[ "${HERMIT_ENV:-}" == "$PWD" && "$(command -v cargo)" == "$PWD"/* ]] \
  || die "hermit did not activate; cargo is $(command -v cargo)"
just desktop-install-ci
(cd desktop && node scripts/set-version-from-tag.mjs "$VERSION")
(cd desktop/src-tauri && cargo update --workspace)

export BUZZ_UPDATER_ENDPOINT="$ENDPOINT"
(cd desktop && node scripts/build-release-config.mjs)
# Our identifier rides in the same generated overlay, so tauri.conf.json keeps
# Block's value and upstream syncs never conflict on it.
jq --arg id "$IDENTIFIER" '.identifier = $id' desktop/src-tauri/tauri.release.conf.json \
  > desktop/src-tauri/tauri.release.conf.json.tmp
mv desktop/src-tauri/tauri.release.conf.json.tmp desktop/src-tauri/tauri.release.conf.json

cargo build --release -p buzz-acp -p buzz-agent -p buzz-backend-kubernetes \
  -p buzz-dev-mcp -p git-credential-nostr -p buzz-cli
./scripts/bundle-sidecars.sh

# No --features mesh-llm: we do not run Share Compute, and leaving it out
# skips the llama.cpp native build. Tauri signs with APPLE_SIGNING_IDENTITY,
# notarizes with the APPLE_API_* key, and signs the updater archive with
# TAURI_SIGNING_PRIVATE_KEY. build.rs only compiles the updater in when both
# BUZZ_UPDATER_* variables are set, as they are here.
(cd desktop && MACOSX_DEPLOYMENT_TARGET=10.15 \
  pnpm tauri build --config src-tauri/tauri.release.conf.json)

# ── verify ───────────────────────────────────────────────────────────────────
BUNDLE="desktop/src-tauri/target/release/bundle"
APP="${BUNDLE}/macos/Buzz.app"
PLIST="${APP}/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
[[ "$(plist CFBundleIdentifier)" == "$IDENTIFIER" ]] || die "bundle identifier is $(plist CFBundleIdentifier)"
[[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || die "bundle version is $(plist CFBundleShortVersionString)"
# instance_reaper.rs:5-12 recognises a live desktop by this executable name;
# any other name gets our agents killed by a co-installed Block Desktop.
[[ "$(plist CFBundleExecutable)" == "buzz-desktop" ]] || die "executable is $(plist CFBundleExecutable)"
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNING="$(codesign -dv "$APP" 2>&1)"
grep -q "^TeamIdentifier=${TEAM}$" <<<"$SIGNING" || die "app is not signed by team ${TEAM}"
spctl --assess --type execute --verbose=4 "$APP"
xcrun stapler validate "$APP"
desktop/scripts/verify-macos-entitlements.sh "$APP"

ARCHIVE="${BUNDLE}/macos/Buzz.app.tar.gz"
[[ -f "$ARCHIVE" && -f "${ARCHIVE}.sig" ]] || die "missing updater archive or signature"
# Tauri only warns when the signing key does not match the embedded public key.
[[ "$(key_id "$(cat "${ARCHIVE}.sig")")" == "$UPDATER_KEY_ID" ]] \
  || die "updater archive is signed by key $(key_id "$(cat "${ARCHIVE}.sig")"), expected ${UPDATER_KEY_ID}"
DMG="$(find "${BUNDLE}/dmg" -name '*.dmg' -type f | head -1)"
[[ -n "$DMG" ]] || die "missing DMG"
# The DMG is how the first install happens; Tauri signs it but does not notarize it.
xcrun notarytool submit "$DMG" --key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY" \
  --issuer "$APPLE_API_ISSUER" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

rm -rf "$OUT"
mkdir -p "$OUT"
ASSET="Buzz_${VERSION}_aarch64.app.tar.gz"
cp "$ARCHIVE" "${OUT}/${ASSET}"
cp "${ARCHIVE}.sig" "${OUT}/${ASSET}.sig"
cp "$DMG" "${OUT}/"
desktop/scripts/generate-oss-latest-json.sh "$VERSION" \
  "${PLATFORM}:${OUT}/${ASSET}.sig:https://github.com/${REPO}/releases/download/${TAG}/${ASSET}" \
  > "${OUT}/latest.json"
( cd "$OUT" && shasum -a 256 ./* )
echo "Verified. Artifacts: ${OUT}"

if [[ "$PUBLISH" != "1" ]]; then
  echo "Not published. Re-run with --publish to release ${TAG}."
  exit 0
fi

# ── publish ──────────────────────────────────────────────────────────────────
# Draft first: a draft creates no tag, so a failed upload can be deleted and
# the run repeated. Publishing the draft creates the tag.
gh release create "$TAG" -R "$REPO" --target "$SHA" --latest=false --draft \
  --title "Buzz Desktop ${VERSION} (aitaco)" \
  --notes "Buzz Desktop ${VERSION}, identifier ${IDENTIFIER}, built from ${SHA}. Updater feed: ${ENDPOINT}" \
  "${OUT}/$(basename "$DMG")" "${OUT}/${ASSET}" "${OUT}/${ASSET}.sig"
gh release edit "$TAG" -R "$REPO" --draft=false
echo "Released ${TAG}. Artifacts stay in ${OUT}."

# Moving the feed is what updates installed copies. If anything below fails,
# the release stands; finish with:
#   gh release upload ${FEED_TAG} -R ${REPO} ${OUT}/latest.json --clobber
if ! gh release view "$FEED_TAG" -R "$REPO" --json tagName >/dev/null; then
  gh release create "$FEED_TAG" -R "$REPO" --target "$SHA" --latest=false \
    --title "Buzz Desktop updater feed (aitaco)" \
    --notes "Holds latest.json for installed aitaco Desktop builds. Do not delete."
fi
# Check again right before moving the feed: another run may have moved it.
PUBLISHED="$(feed_version)"
if [[ -n "$PUBLISHED" ]]; then
  [[ "$(printf '%s\n%s\n' "$PUBLISHED" "$VERSION" | sort -V | tail -1)" == "$VERSION" && "$PUBLISHED" != "$VERSION" ]] \
    || die "the feed now serves ${PUBLISHED}; not moving it to ${VERSION}"
fi
gh release upload "$FEED_TAG" -R "$REPO" "${OUT}/latest.json" --clobber

# The feed is what installed apps read; confirm it serves this version.
for _ in 1 2 3 4 5 6; do
  if curl -fsSL "$ENDPOINT" | jq -e --arg v "$VERSION" '.version == $v' >/dev/null; then
    echo "Published ${TAG}; ${ENDPOINT} serves ${VERSION}."
    exit 0
  fi
  sleep 10
done
die "published ${TAG}, but ${ENDPOINT} does not serve ${VERSION} yet"

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

die() { echo "desktop-release: $*" >&2; exit 1; }

# ── preflight ────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || die "run this on an Apple Silicon Mac"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 <X.Y.Z> [--publish]"
cd "$(git rev-parse --show-toplevel)"
for tool in jq gh git curl codesign spctl xcrun; do
  command -v "$tool" >/dev/null || die "missing tool: $tool"
done
for var in APPLE_SIGNING_IDENTITY APPLE_API_ISSUER APPLE_API_KEY APPLE_API_KEY_PATH \
           TAURI_SIGNING_PRIVATE_KEY BUZZ_UPDATER_PUBLIC_KEY; do
  [[ -n "${!var:-}" ]] || die "missing environment variable: $var (see the runbook)"
done
[[ "$APPLE_SIGNING_IDENTITY" == *"(${TEAM})" ]] \
  || die "APPLE_SIGNING_IDENTITY must be a Developer ID for team ${TEAM}"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "working tree has changes"

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
PUBLISHED="$(curl -fsSL "$ENDPOINT" 2>/dev/null | jq -r '.version // empty' || true)"
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
codesign -dv "$APP" 2>&1 | grep -q "^TeamIdentifier=${TEAM}$" || die "app is not signed by team ${TEAM}"
spctl --assess --type execute --verbose=4 "$APP"
xcrun stapler validate "$APP"
desktop/scripts/verify-macos-entitlements.sh "$APP"

ARCHIVE="${BUNDLE}/macos/Buzz.app.tar.gz"
[[ -f "$ARCHIVE" && -f "${ARCHIVE}.sig" ]] || die "missing updater archive or signature"
DMG="$(find "${BUNDLE}/dmg" -name '*.dmg' -type f | head -1)"
[[ -n "$DMG" ]] || die "missing DMG"

OUT="$(mktemp -d "${TMPDIR:-/tmp}/aitaco-desktop-${VERSION}.XXXXXX")"
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
gh release create "$TAG" -R "$REPO" --target "$SHA" --latest=false \
  --title "Buzz Desktop ${VERSION} (aitaco)" \
  --notes "Buzz Desktop ${VERSION}, identifier ${IDENTIFIER}, built from ${SHA}. Updater feed: ${ENDPOINT}" \
  "${OUT}/$(basename "$DMG")" "${OUT}/${ASSET}" "${OUT}/${ASSET}.sig"
if ! gh release view "$FEED_TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release create "$FEED_TAG" -R "$REPO" --target "$SHA" --latest=false \
    --title "Buzz Desktop updater feed (aitaco)" \
    --notes "Holds latest.json for installed aitaco Desktop builds. Do not delete."
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

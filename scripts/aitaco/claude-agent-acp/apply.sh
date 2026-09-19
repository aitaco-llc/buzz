#!/usr/bin/env bash
# aitaco: carry the steered-turn idle-debt fix on an installed claude-agent-acp
# 0.79.0 until upstream ships one. See README.md in this directory.
#
#   scripts/aitaco/claude-agent-acp/apply.sh check  [<package-dir>]
#       Read-only. Reports version, the acp-agent.js sha256, and whether the
#       fix is applied.
#   scripts/aitaco/claude-agent-acp/apply.sh apply  [<package-dir>]
#       Keeps the original as dist/acp-agent.js.orig-0.79.0, writes the patched
#       file next to it, checks its syntax and sha256, then renames it into place.
#   scripts/aitaco/claude-agent-acp/apply.sh revert [<package-dir>]
#       Renames the kept original back into place.
#
# <package-dir> defaults to $(npm root -g)/@agentclientprotocol/claude-agent-acp.
# On the Mac seats the package lives in Buzz Desktop's node-tools; see README.md.
# The fleet runs this package, so apply and revert are fleet deploys. Node reads
# the file when an adapter process starts: running processes keep the code they
# loaded, and every adapter buzz-acp spawns afterwards gets the new file.
set -euo pipefail

die() { echo "claude-agent-acp/apply: $*" >&2; exit 1; }
# The fleet has GNU (hip) and BSD (the Mac) userlands; use flags both accept.
sha256() {
  if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1
}
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$HERE/steer-idle-debt-0.79.0.patch"
VERSION="0.79.0"
# sha256 of dist/acp-agent.js as published in 0.79.0, and after this patch.
PRE_SHA="e9711af5c5dd150718c4a22b1760f913ce8a871b7355d1f0f63aa845d282e37c"
POST_SHA="983ca6c3cd0fe4d594c76072a8f3667a3aff07190a1009600d4d5e5bd47b8708"

CMD="${1:-}"
[[ "$CMD" == "check" || "$CMD" == "apply" || "$CMD" == "revert" ]] \
  || die "usage: $0 check|apply|revert [<package-dir>]"
PKG="${2:-$(npm root -g)/@agentclientprotocol/claude-agent-acp}"
TARGET="$PKG/dist/acp-agent.js"
ORIG="$TARGET.orig-$VERSION"
[[ -f "$TARGET" ]] || die "no $TARGET"

version="$(node -p "require(process.argv[1]).version" "$PKG/package.json")"
sha="$(sha256 "$TARGET")"
case "$sha" in
  "$PRE_SHA") state="unpatched" ;;
  "$POST_SHA") state="patched" ;;
  *) state="unknown" ;;
esac
echo "package:  $PKG"
echo "version:  $version"
echo "sha256:   $sha ($state)"

case "$CMD" in
  check)
    [[ "$version" == "$VERSION" ]] || echo "note: this patch targets $VERSION only"
    ;;
  apply)
    [[ "$version" == "$VERSION" ]] || die "installed version is $version; this patch targets $VERSION"
    [[ "$state" == "patched" ]] && { echo "already applied"; exit 0; }
    [[ "$state" == "unpatched" ]] || die "acp-agent.js matches neither the published $VERSION file nor the patched one; not touching it"
    [[ -e "$ORIG" ]] || cp -p "$TARGET" "$ORIG"
    # node --check needs a .js name, so the temp file sits in a temp directory.
    tmpdir="$(mktemp -d "$PKG/dist/.acp-agent.XXXXXX")"
    trap 'rm -rf "$tmpdir"' EXIT
    tmp="$tmpdir/acp-agent.js"
    patch -s -o "$tmp" "$TARGET" "$PATCH_FILE"
    chmod "$(file_mode "$TARGET")" "$tmp"
    node --check "$tmp"
    [[ "$(sha256 "$tmp")" == "$POST_SHA" ]] || die "patched file has an unexpected sha256"
    mv -f "$tmp" "$TARGET"
    echo "applied:  $(sha256 "$TARGET"); original kept at $ORIG"
    ;;
  revert)
    [[ "$state" == "unpatched" ]] && { echo "already unpatched"; exit 0; }
    [[ -f "$ORIG" ]] || die "no kept original at $ORIG"
    [[ "$(sha256 "$ORIG")" == "$PRE_SHA" ]] || die "$ORIG is not the published $VERSION file"
    tmpdir="$(mktemp -d "$PKG/dist/.acp-agent.XXXXXX")"
    trap 'rm -rf "$tmpdir"' EXIT
    cp -p "$ORIG" "$tmpdir/acp-agent.js"
    mv -f "$tmpdir/acp-agent.js" "$TARGET"
    echo "reverted: $(sha256 "$TARGET")"
    ;;
esac

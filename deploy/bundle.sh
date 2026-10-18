#!/usr/bin/env bash
# Verifies a StardustDB release ZIP and extracts it into third_party/:
#   a bundle for this machine        -> third_party/stardust          (local builds)
#   any other platform's bundle      -> third_party/stardust-<target> (e.g. linux_amd64, for servers)
#
#   STARDUST_MINISIGN_KEY=<key> bash deploy/bundle.sh <stardust-release.zip>
#
# STARDUST_MINISIGN_KEY is StardustDB's published minisign public key: take it
# from StardustDB's installation page, never from the archive itself. The
# bundle's signed SHA256SUMS and every checksum are checked; with the ZIP's
# .minisig beside it, the ZIP is checked too. Needs minisign and unzip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="${1:?usage: STARDUST_MINISIGN_KEY=<key> bash deploy/bundle.sh <stardust-release.zip>}"
KEY="${STARDUST_MINISIGN_KEY:?set STARDUST_MINISIGN_KEY to the minisign public key that StardustDB publishes}"
command -v minisign >/dev/null || { echo "install minisign (brew install minisign / apt install minisign)"; exit 1; }
[ -f "$ZIP.minisig" ] && minisign -Vm "$ZIP" -P "$KEY"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unzip -q "$ZIP" -d "$TMP"
DIR="$(dirname "$(find "$TMP" -maxdepth 2 -name manifest.json | head -1)")"
[ -f "$DIR/manifest.json" ] || { echo "$ZIP holds no StardustDB bundle (no manifest.json)"; exit 1; }
(cd "$DIR" && minisign -Vm SHA256SUMS -P "$KEY" >/dev/null \
  && { sha256sum -c SHA256SUMS --quiet 2>/dev/null || shasum -a 256 -c SHA256SUMS --quiet; })
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" "$DIR/manifest.json"; }
target="$(field target)" version="$(field version)"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) here=darwin_arm64 ;; Darwin-x86_64) here=darwin_amd64 ;;
  Linux-x86_64) here=linux_amd64 ;; Linux-aarch64) here=linux_arm64 ;; *) here=none ;;
esac
DEST="$ROOT/third_party/stardust-$target"
[ "$target" = "$here" ] && DEST="$ROOT/third_party/stardust"
mkdir -p "$ROOT/third_party"
rm -rf "$DEST"; mv "$DIR" "$DEST"
command -v xattr >/dev/null && xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
echo "StardustDB $version $target: signature and checksums verified -> ${DEST#"$ROOT"/}"

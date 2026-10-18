#!/usr/bin/env bash
# Builds the server and the seed importer. StardustDB is linked statically from
# the release bundle in third_party/stardust, so the binary needs no library
# files at run time. TARGET_CPU (default native) sets the instruction baseline.
set -euo pipefail
cd "$(dirname "$0")"
if [[ -x /opt/twelve-rust/cargo/bin/cargo ]]; then
  export RUSTUP_HOME=/opt/twelve-rust/rustup RUSTUP_TOOLCHAIN=1.94.0
  export PATH="/opt/twelve-rust/cargo/bin:$PATH"
else
  export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
fi
# The bundle must exist and match this machine.
B=../third_party/stardust
[ -f "$B/manifest.json" ] && [ -f "$B/abi/bindings/rust/Cargo.toml" ] || {
  echo "no StardustDB bundle in third_party/stardust (see README: Requirements)" >&2; exit 1; }
target="$(sed -n 's/.*"target":"\([^"]*\)".*/\1/p' "$B/manifest.json")"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) want="darwin_arm64" ;;
  Darwin-x86_64) want="darwin_amd64" ;;
  Linux-x86_64) want="linux_amd64" ;;
  Linux-aarch64) want="linux_arm64" ;;
  *) want="?" ;;
esac
[ "$target" = "$want" ] || { echo "third_party/stardust is the $target bundle; this machine needs $want" >&2; exit 1; }
export STARDUST_LIBRARY_DIR="$(cd "$B/lib" && pwd)"
export RUSTFLAGS="-C target-cpu=${TARGET_CPU:-native} ${RUSTFLAGS:-}"
cargo build --release --locked "$@"

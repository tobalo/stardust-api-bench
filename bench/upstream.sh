#!/usr/bin/env bash
# Fetches the challenge's own files into bench/.upstream/ (git-ignored), pinned to
# one commit and checked against SHA-256, so this repo runs them unmodified
# instead of carrying copies:
#   seed/generate.mjs    the deterministic seed generator
#   bench/load.js        the k6 load test that scores a server
#   test/test.sh         the 42 API checks, with test/golden/*.json
# Reruns only download what is missing or changed. Prints the cache directory.
#
#   bash bench/upstream.sh
set -euo pipefail
COMMIT=026bdb68d94d0d932bb5981321ad82c70618d752
URL="https://raw.githubusercontent.com/arjaythedev/twelve-dollar-server-challenge/$COMMIT"
DIR="$(cd "$(dirname "$0")" && pwd)/.upstream"
FILES=(
  "seed/generate.mjs            fc72b640c06ac77606db1b5d12f3ad4aab60f96c2001a6d4f70e47694b8ec401"
  "bench/load.js                14fbbe36a7bef2cc803c8c2309b8b93d6e6ec9c2b6aba78ebe3b9a95ebf85972"
  "test/test.sh                 679e722044fd1f366d85093232e7f2ec2e3398ea312032dd9eb6cbdf8b17306a"
  "test/golden/feed.json        8c9b3d6cb46e650c4786ab9281bc3a72ba7bd75b7926021d2b0c431dd9bd3d68"
  "test/golden/post-1.json      8035350dc55714c9a673af9f441ab07d2b269047e1137612f022877b9e8f3652"
  "test/golden/post-250000.json febb2506b9d4a99bc34f1f182c61ced6b3ba3b2533724485c6e5206604a65b71"
  "test/golden/post-500000.json 662fe8c7282dee8aab00dab6cdb15e64e953f10a2c1c923e2ea67fab1429a4de"
)
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

for entry in "${FILES[@]}"; do
  read -r path hash <<< "$entry"
  file="$DIR/$path"
  [ -f "$file" ] && [ "$(sha256 "$file")" = "$hash" ] && continue
  mkdir -p "$(dirname "$file")"
  curl -fsSL --retry 3 "$URL/$path" -o "$file.part"
  got="$(sha256 "$file.part")"
  [ "$got" = "$hash" ] || { rm -f "$file.part"; echo "upstream.sh: $path has SHA-256 $got, expected $hash" >&2; exit 1; }
  mv "$file.part" "$file"
done
echo "$DIR"

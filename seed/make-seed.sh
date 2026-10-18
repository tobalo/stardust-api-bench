#!/usr/bin/env bash
# Builds seed/feed.stardust, seed/tokens.json and seed/seed-metrics.json from the
# challenge's deterministic generator (50k users, 500k posts, ~2M likes),
# fetched pinned by bench/upstream.sh.
#
#   bash seed/make-seed.sh
#
# Needs node >= 18, python3, a Stardust license and ~8 GB of RAM for the import (the
# first transaction holds all 550k posts and users). The file is portable:
# build it on any machine and upload it (make up does).
# Never serve feed.stardust directly: every run starts from a fresh copy.
# SEED_DIR picks where feed.stardust and tokens.json go (default: seed/).
set -euo pipefail
command -v python3 >/dev/null || { echo 'make-seed: install python3 for seed measurements' >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SUB="$HERE/../server"
OUT="${SEED_DIR:-$HERE}"; mkdir -p "$OUT"
TSV="$(mktemp -d)"; trap 'rm -rf "$TSV"' EXIT
UPSTREAM="$(bash "$HERE/../bench/upstream.sh")"
node "$UPSTREAM/seed/generate.mjs" "$TSV"
mv "$TSV/tokens.json" "$OUT/tokens.json"
bash "$SUB/build.sh" --bin import
rm -f "$OUT/feed.stardust" "$OUT/seed-metrics.json"
python3 "$HERE/measure.py" "$TSV" "$OUT/feed.stardust" "${CARGO_TARGET_DIR:-$SUB/target}/release/import"
echo "OK: $OUT/feed.stardust ($(du -h "$OUT/feed.stardust" | cut -f1) on disk)"

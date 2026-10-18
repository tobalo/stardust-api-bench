#!/usr/bin/env bash
# The 42 API checks on this machine: builds the server, starts it on a fresh
# copy of seed/feed.stardust, runs the challenge's test/test.sh (fetched
# pinned by bench/upstream.sh), and stops it. (On macOS the
# server runs its portable thread-per-connection mode; Linux runs io_uring.)
#
#   bash bench/check.sh          # or: make check
#
# Needs seed/feed.stardust (make seed) and a StardustDB license.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="${SEED:-$ROOT/seed/feed.stardust}"
[ -f "$SEED" ] || { echo "no $SEED: make seed"; exit 1; }
PORT="${PORT:-3000}"
RUN="$(mktemp -d)"
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null; wait 2>/dev/null; rm -f "$RUN/feed.stardust" "$RUN/server.log"; rmdir "$RUN" 2>/dev/null || true; }
trap cleanup EXIT

UPSTREAM="$(bash "$ROOT/bench/upstream.sh")"
bash "$ROOT/server/build.sh" -q
# A copy-on-write clone where the filesystem has one (APFS, XFS, Btrfs); else a full copy.
cp -c "$SEED" "$RUN/feed.stardust" 2>/dev/null || cp --reflink=auto "$SEED" "$RUN/feed.stardust"
STARDUST_PATH="$RUN/feed.stardust" JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT="$PORT" \
  "$ROOT/server/target/release/stardust-uring" > "$RUN/server.log" 2>&1 &
PID=$!
for _ in $(seq 60); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
curl -sf "http://127.0.0.1:$PORT/health" >/dev/null || { echo "no healthy /health after 60 s"; cat "$RUN/server.log"; exit 1; }
bash "$UPSTREAM/test/test.sh" "http://127.0.0.1:$PORT" || { echo "== server log (last 30 lines)"; tail -30 "$RUN/server.log"; exit 1; }

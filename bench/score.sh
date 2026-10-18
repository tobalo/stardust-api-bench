#!/usr/bin/env bash
# The challenge's scoring procedure (its README, "Scoring") against a running
# server, from the k6 machine:
#   1. warm-up: 1,000 users for 2 minutes, not scored;
#   2. search: bench/load.js from 2,500 users, doubling until a run fails, then
#      narrowing to within 250 users;
#   3. confirm: a 5-minute hold at that number; on failure step down 250 users.
# The score is the most users that pass a 5-minute hold (p95 < 500 ms,
# p99 < 1 s, < 1% errors: load.js's thresholds; k6 exits non-zero on a miss).
#
#   BASE_URL=http://10.0.0.5 PROFILE=stock bash bench/score.sh
#
# ONLY=<users> runs one load test (RAMP_UP, then HOLD) instead of the procedure.
# REDLINE="<users> ..." continues past the score, one SEARCH-long run per step,
# to find the peak throughput and where it breaks; it stops when errors pass
# 50% or the server stops answering /health.
# CONNECTIONS="<connections> ..." instead holds that many keep-alive connections
# for HOLD each (bench/connections.js, spread over every address in BASE_URLS),
# and stops at the first step that misses a threshold.
# Each run writes its k6 log, JSON summary and web-dashboard HTML (charts over
# time) to OUT, and one row to OUT/runs.csv for bench/report.py.
# Env: BASE_URL (required), BASE_URLS (every server address, comma-separated, for CONNECTIONS),
#      PROFILE (stock|tuned, recorded with the results),
#      START=2500 STEP=250 WARMUP_VUS=1000 WARMUP=2m SEARCH=2m HOLD=5m RAMP_UP=60s,
#      TOKENS=seed/tokens.json, OUT=bench/results/<UTC timestamp>-<profile>.
# Restart the server (a fresh database) before each scoring session, not between runs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${BASE_URL:?set BASE_URL, e.g. http://10.0.0.5}"
PROFILE="${PROFILE:-stock}"
START="${START:-2500}" STEP="${STEP:-250}" WARMUP_VUS="${WARMUP_VUS:-1000}"
WARMUP="${WARMUP:-2m}" SEARCH="${SEARCH:-2m}" HOLD="${HOLD:-5m}" RAMP_UP="${RAMP_UP:-60s}"
TOKENS="$(cd "$(dirname "${TOKENS:-$ROOT/seed/tokens.json}")" && pwd)/$(basename "${TOKENS:-tokens.json}")"
OUT="${OUT:-$ROOT/bench/results/$(date -u +%Y%m%dT%H%M%SZ)-$PROFILE}"
LOAD="$ROOT/bench/.upstream/bench/load.js"
[ -f "$LOAD" ] || bash "$ROOT/bench/upstream.sh" >/dev/null
command -v k6 >/dev/null || { echo "k6 is not installed (https://grafana.com/docs/k6/latest/set-up/install-k6/)"; exit 1; }
[ -f "$TOKENS" ] || { echo "no $TOKENS: copy seed/tokens.json from the machine that built the seed"; exit 1; }
curl -sf "$BASE_URL/health" >/dev/null || { echo "no healthy $BASE_URL/health"; exit 1; }
mkdir -p "$OUT"
log() { echo "$*" | tee -a "$OUT/summary.txt"; }
[ -f "$OUT/runs.csv" ] || echo "label,users,hold,start,end,result,p95_ms,p99_ms,errors_pct,requests,rps,client_rx_kbps" > "$OUT/runs.csv"
log "profile=$PROFILE base_url=$BASE_URL k6=$(k6 version | head -1) start=$(date -u +%FT%TZ)"
log "client nofile=$(ulimit -n) $(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null | tr '\t' ' ' | sed 's/^/ports=/')"

# run <users> <hold> <label> [script]: 0 when every threshold passes.
run() {
  local vus=$1 hold=$2 label=$3 script=${4:-$LOAD} rc=0 start end
  start="$(date +%s)"
  K6_WEB_DASHBOARD=true K6_WEB_DASHBOARD_EXPORT="$OUT/$label-$vus.html" K6_WEB_DASHBOARD_PERIOD=5s \
    k6 run --quiet -e BASE_URL="$BASE_URL" -e BASE_URLS="${BASE_URLS:-}" -e VUS="$vus" -e DURATION="$hold" -e RAMP_UP="$RAMP_UP" \
    -e TOKENS="$TOKENS" --summary-export "$OUT/$label-$vus.json" "$script" \
    > "$OUT/$label-$vus.log" 2>&1 || rc=$?
  end="$(date +%s)"
  local result stats row
  result="$([ $rc = 0 ] && echo PASS || echo "FAIL($rc)")"
  row="$(jq -r '[.metrics.http_req_duration["p(95)"], .metrics.http_req_duration["p(99)"], .metrics.http_req_failed.value * 100, .metrics.http_reqs.count, .metrics.http_reqs.rate, .metrics.data_received.rate * 8 / 1000] | map(. * 100 | round / 100) | @csv' \
    "$OUT/$label-$vus.json" 2>/dev/null || echo ',,,,,')"
  echo "$label,$vus,$hold,$start,$end,${result%%(*},$row" >> "$OUT/runs.csv"
  stats="$(jq -r '[.metrics.http_req_duration["p(95)"], .metrics.http_req_duration["p(99)"], .metrics.http_req_failed.value * 100, .metrics.http_reqs.count, .metrics.http_reqs.rate] | "p95=\(.[0]|floor)ms p99=\(.[1]|floor)ms errors=\(.[2]*100|floor/100)% reqs=\(.[3]) rps=\(.[4]|floor)"' \
    "$OUT/$label-$vus.json" 2>/dev/null || echo "no summary")"
  log "$(printf '%-8s %7s users %-5s %s %s' "$label" "$vus" "$hold" "$result" "$stats")"
  return $rc
}

# stop_after <label> <users>: 0 when errors passed 50% or /health stopped answering.
stop_after() {
  local errors
  errors="$(jq '.metrics.http_req_failed.value * 100 | floor' "$OUT/$1-$2.json" 2>/dev/null || echo 100)"
  if ! curl -sf -m 10 "$BASE_URL/health" >/dev/null; then log "the server stopped answering after $2: stop"; return 0; fi
  if [ "$errors" -gt 50 ]; then log "errors ${errors}% at $2: stop"; return 0; fi
  return 1
}

if [ -n "${CONNECTIONS:-}" ]; then
  # k6 needs ~0.2 MB per VU: collect garbage sooner so 125k VUs fit a 32 GB client.
  export GOGC="${GOGC:-50}"
  [ -r /proc/meminfo ] && export GOMEMLIMIT="${GOMEMLIMIT:-$(awk '/^MemTotal/{printf "%dMiB", $2 * 0.85 / 1024}' /proc/meminfo)}"
  held=0
  for n in $CONNECTIONS; do
    if ! run "$n" "$HOLD" conns "$ROOT/bench/connections.js"; then
      stop_after conns "$n" || true
      log "$n connections missed a threshold: stop"
      break
    fi
    held=$n
    # Let the kernel free the sockets this step just closed before the next ramp.
    sleep "${SETTLE:-120}"
  done
  log "CONNECTIONS held $held keep-alive connections for $HOLD within the thresholds (tried: $CONNECTIONS) end=$(date -u +%FT%TZ)"
  exit 0
fi

if [ -n "${ONLY:-}" ]; then
  if run "$ONLY" "$HOLD" single; then log "PASS at $ONLY users"; else log "FAIL at $ONLY users"; fi
  exit 0
fi

run "$WARMUP_VUS" "$WARMUP" warmup || true

pass=0 fail=0 vus=$START
while run "$vus" "$SEARCH" search; do pass=$vus; vus=$((vus * 2)); done
fail=$vus
while [ $((fail - pass)) -gt "$STEP" ]; do
  mid=$(( (pass + fail) / 2 / STEP * STEP ))
  [ "$mid" -le "$pass" ] && mid=$((pass + STEP))
  if run "$mid" "$SEARCH" search; then pass=$mid; else fail=$mid; fi
done

score=0 vus=$pass
while [ "$vus" -gt 0 ]; do
  if run "$vus" "$HOLD" confirm; then score=$vus; break; fi
  vus=$((vus - STEP))
done
log "SCORE profile=$PROFILE users=$score (search: highest pass $pass, lowest fail $fail) end=$(date -u +%FT%TZ)"

if [ -n "${REDLINE:-}" ]; then
  log "== redline: past the limits, for the peak throughput and the breaking point"
  for vus in $REDLINE; do
    run "$vus" "$SEARCH" redline || true
    stop_after redline "$vus" && break
  done
  log "$(tail -n +2 "$OUT/runs.csv" | sort -t, -k11 -g | tail -1 | awk -F, '{printf "PEAK %s req/s at %s users (%s run: p95 %s ms, p99 %s ms, errors %s%%)", $11, $2, $1, $7, $8, $9}')"
fi

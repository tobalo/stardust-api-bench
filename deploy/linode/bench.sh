#!/usr/bin/env bash
# Benchmarks the Linode server and builds a report. k6 runs on the k6 client
# Linode when up.sh --client created one (a datacenter link, same region),
# otherwise on this machine (BENCH_CLIENT=local forces this machine). Each
# session restarts the server first (a fresh database), samples the server's
# CPU, memory, network, disk and database allocation every second while k6 runs, and collects the
# server's own 5-second stats (request mix, read time, Stardust group commits).
# Everything lands in bench/results/<label>/, with report.html, this script's
# whole console output (bench.log) and the last deploy's (deploy.log, from
# up.sh). Before anything is written there, IP addresses become placeholders
# (SERVER_IP, CLIENT_IP, ...) and the license status line is dropped.
#
#   bash deploy/linode/bench.sh              # challenge scoring: warm-up, search, 5-minute confirm
#   bash deploy/linode/bench.sh --vus 1000   # one load test: 60 s ramp, 5-minute hold
#   bash deploy/linode/bench.sh --redline    # scoring, then 10k..64k users: peak and breaking point
#   bash deploy/linode/bench.sh --connections  # keep-alive connections, 70k and up, over every server address
#
# BENCH_HOST=root@<ip> (and BENCH_TYPE, a label) targets another server than the
# Terraform one. CONNECTIONS (the --connections ladder), HOLD, RAMP_UP, START, STEP, SEARCH, WARMUP and WARMUP_VUS pass
# through to bench/score.sh. Needs jq and python3, plus k6 when it runs here;
# then it keeps the Mac awake (caffeinate) and raises its descriptor limit.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
die() { echo "bench: $*" >&2; exit 1; }
ONLY=""
case "${1:-}" in
  --vus) ONLY="${2:?--vus needs a user count}" ;;
  --redline) export REDLINE="${REDLINE:-10000 15000 20000 30000 45000 64000}" ;;
  --connections) export CONNECTIONS="${CONNECTIONS:-70000 125000 200000 300000 400000 500000}" ;;
  "") ;;
  *) die "usage: bench.sh [--vus <users> | --redline | --connections]" ;;
esac
for tool in jq python3; do command -v "$tool" >/dev/null || die "install $tool"; done
if [ -n "${BENCH_HOST:-}" ]; then
  TARGET="$BENCH_HOST" TYPE="${BENCH_TYPE:-custom}"
else
  TF="$(command -v tofu || command -v terraform)"
  TARGET="root@$("$TF" -chdir="$HERE" output -raw bench_ip)" TYPE="$("$TF" -chdir="$HERE" output -raw bench_type)"
  IP6="$("$TF" -chdir="$HERE" output -raw bench_ipv6 2>/dev/null || true)"
  EXTRA6=($("$TF" -chdir="$HERE" output -json bench_ipv6_extra 2>/dev/null | jq -r '.[]?' || true))
fi
IP="${TARGET#*@}"
# Every server address: one client opens ~64,500 connections to each.
BASE_URLS="http://$IP${IP6:+,http://[$IP6]}"
for a in ${EXTRA6[@]+"${EXTRA6[@]}"}; do BASE_URLS+=",http://[$a]"; done
CLIENT_IP=""
if [ -z "${BENCH_HOST:-}" ] && [ "${BENCH_CLIENT:-}" != local ]; then
  CLIENT_IP="$("$TF" -chdir="$HERE" output -raw client_ip 2>/dev/null || true)"
  CLIENT_TYPE="$("$TF" -chdir="$HERE" output -raw client_type 2>/dev/null || true)"
fi
TOKENS="${TOKENS:-$ROOT/seed/tokens.json}"
[ -s "$TOKENS" ] || die "no $TOKENS (up.sh builds it with the seed)"
# One SSH connection per host for the whole session, opened before any load:
# polls and file copies reuse it instead of opening new connections to a box
# that is holding hundreds of thousands of them.
CTL="$(mktemp -d /tmp/sdb.XXXXXX)"
SSH=(ssh -i "${BENCH_SSH_KEY:-$HERE/.ssh/id_ed25519}" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HERE/.ssh/known_hosts" -o ServerAliveInterval=30 -o ConnectTimeout=30
  -o ControlMaster=auto -o ControlPath="$CTL/%C" -o ControlPersist=yes)
on() { "${SSH[@]}" "$TARGET" "$@"; }
client() { "${SSH[@]}" "root@$CLIENT_IP" "$@"; }
[ -n "$CLIENT_IP" ] || command -v k6 >/dev/null || die "install k6, or create a client Linode with up.sh --client"

ulimit -n 65536 2>/dev/null || ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
# The first SSH of a session can stall on a fresh box: retry it before giving up.
PROFILE=""
for _ in 1 2 3 4 5; do
  PROFILE="$(on 'test -e /etc/sysctl.d/90-stardust-bench.conf && echo tuned || echo stock')" && break
  sleep 10
done
[ -n "$PROFILE" ] || die "no SSH to $TARGET"
LABEL="$(date -u +%Y%m%dT%H%M%SZ)-$TYPE-$PROFILE${ONLY:+-$ONLY}${REDLINE:+-redline}${CONNECTIONS:+-connections}"
OUT="$ROOT/bench/results/$LABEL"
mkdir -p "$OUT"
RAWLOG="$OUT/.bench.log.unredacted"
exec > >(tee "$RAWLOG") 2>&1
storage_snapshot() {
  local snapshot
  snapshot="$(on "bash -s -- $1" < "$ROOT/deploy/host/storage.sh")" || { echo "warning: storage snapshot $1 failed" >&2; return 0; }
  if [ -s "$OUT/storage-snapshots.csv" ]; then
    printf '%s\n' "$snapshot" | tail -n +2 >> "$OUT/storage-snapshots.csv"
  else
    printf '%s\n' "$snapshot" > "$OUT/storage-snapshots.csv"
  fi
}
# Preserve the preceding database's size before ExecStartPre replaces it.
storage_snapshot before_reset
[ -z "${CONNECTIONS:-}" ] || echo "== connections over $(echo "$BASE_URLS" | tr ',' '\n' | wc -l | tr -d ' ') server addresses"
echo "== fresh database on $IP ($TYPE, $PROFILE); client nofile $(ulimit -n)"
on 'systemctl restart stardust-bench && for _ in $(seq 120); do curl -sf http://127.0.0.1/health >/dev/null && exit 0; sleep 1; done; exit 1' \
  || die "the server did not come back healthy"
SINCE="$(on 'date +%s')"
storage_snapshot session_start
# Use this checkout's sampler even when make up has not been run again.
on 'cat > /opt/stardust-bench/bin/storage.sh.next && chmod 0644 /opt/stardust-bench/bin/storage.sh.next && mv /opt/stardust-bench/bin/storage.sh.next /opt/stardust-bench/bin/storage.sh' < "$ROOT/deploy/host/storage.sh"
on 'cat > /opt/stardust-bench/bin/sample-host.next && chmod 0755 /opt/stardust-bench/bin/sample-host.next && mv /opt/stardust-bench/bin/sample-host.next /opt/stardust-bench/bin/sample-host' < "$ROOT/deploy/host/sample-host.sh"
on 'systemctl stop stardust-bench-sampler 2>/dev/null; systemd-run --unit=stardust-bench-sampler --collect --quiet \
  --property=StandardOutput=truncate:/var/lib/stardust-bench/host.csv /opt/stardust-bench/bin/sample-host 1'

collect() {
  storage_snapshot session_end
  on 'systemctl stop stardust-bench-sampler 2>/dev/null; cat /var/lib/stardust-bench/host.csv' > "$OUT/host.csv" || true
  on "journalctl -u stardust-bench --since @$SINCE -o cat | grep '^stats '" > "$OUT/app-stats.log" || true
  on 'echo "plan_cpu=$(lscpu | sed -n "s/^Model name:[[:space:]]*//p")"; echo "vcpus=$(nproc)"; echo "kernel=$(uname -r)";
      echo "mem_total_mb=$(free -m | awk "/^Mem:/{print \$2}")"; echo "swap_mb=$(free -m | awk "/^Swap:/{print \$2}")";
      echo "seed_archive_sha256=$(cat /var/lib/stardust-bench/seed/feed.stardust.sha256 2>/dev/null)";
      echo "filesystem_type=$(stat -f -c %T /var/lib/stardust-bench/run)";
      systemctl show stardust-bench -p LimitNOFILE -p MemoryPeak -p CPUUsageNSec -p NRestarts | sed "s/^/service_/";
      for k in net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range fs.nr_open vm.dirty_ratio; do echo "$k=$(sysctl -n $k | tr "\t" " ")"; done;
      journalctl -u stardust-bench -o cat -n 200 | grep "^listening" | tail -1' > "$OUT/server.txt" 2>&1 || true
  if [ -n "$CLIENT_IP" ]; then
    for _ in 1 2 3 4 5 6; do
      rsync -az -e "${SSH[*]}" "root@$CLIENT_IP:stardust-bench-client/results/$LABEL/" "$OUT/" 2>/dev/null && break
      echo "== copying the k6 results from the client failed; retrying"; sleep 20
    done
    { echo "client_k6=$(client 'k6 version | head -1')"; echo "client_os=Linode $CLIENT_TYPE, same region"
      echo "client_nofile=$(client 'ulimit -n')"; } >> "$OUT/server.txt"
  else
    { echo "client_k6=$(k6 version | head -1)"; echo "client_os=$(uname -sr)"; echo "client_nofile=$(ulimit -n)"; } >> "$OUT/server.txt"
  fi
  { echo "target=$IP"; echo "plan=$TYPE"; echo "profile=$PROFILE"; } >> "$OUT/server.txt"
  for host in "$TARGET" ${CLIENT_IP:+"root@$CLIENT_IP"}; do "${SSH[@]}" -O exit "$host" 2>/dev/null || true; done
  rm -rf "$CTL"
  [ -f "$HERE/up.log" ] && cp "$HERE/up.log" "$OUT/deploy.log"
  mv "$RAWLOG" "$OUT/bench.log"
  redact
  # Past the limit k6 logs every failed request: a log over 5 MB is kept whole, gzipped.
  find "$OUT" -maxdepth 1 -name '*.log' -size +5M -exec gzip -9 {} + || true
  python3 "$ROOT/bench/report.py" "$OUT" && echo "== report: ${OUT#"$ROOT"/}/report.html"
}

# Published sessions carry no addresses or license details: known addresses
# become named placeholders, any other public address REDACTED_IP(V6), and
# license status lines are dropped.
redact() {
  python3 -I - "$OUT" "SERVER_IP=$IP" "SERVER_IPV6=${IP6:-}" "CLIENT_IP=${CLIENT_IP:-}" \
    $(i=0; for a in ${EXTRA6[@]+"${EXTRA6[@]}"}; do i=$((i + 1)); echo "SERVER_IPV6_$i=$a"; done) <<'PY'
import os, re, sys
out, pairs = sys.argv[1], [a.split("=", 1) for a in sys.argv[2:]]
known = sorted(((v, k) for k, v in pairs if v), key=lambda p: -len(p[0]))
ipv4 = re.compile(r"(?<![\d.])(?!127\.0\.0\.1|0\.0\.0\.0)(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
ipv6 = re.compile(r"(?<![0-9a-fA-F:])2[0-9a-f]{3}(?::[0-9a-f]{0,4}){2,7}(?![0-9a-fA-F:])")
for name in os.listdir(out):
    path = os.path.join(out, name)
    if not name.endswith((".log", ".txt", ".csv", ".json", ".html")) or not os.path.isfile(path):
        continue
    text = open(path, encoding="utf-8", errors="surrogateescape").read()
    for value, label in known:
        text = text.replace(value, label)
    text = ipv6.sub("REDACTED_IPV6", ipv4.sub("REDACTED_IP", text))
    text = "".join(l for l in text.splitlines(True) if not re.match(r"\s*license:", l))
    # A new file, renamed over the old: tee may still be appending to bench.log.
    open(path + ".tmp", "w", encoding="utf-8", errors="surrogateescape").write(text)
    os.replace(path + ".tmp", path)
PY
}
trap collect EXIT

if [ -n "$CLIENT_IP" ]; then
  # k6 runs in a transient unit on the client: closing this terminal does not stop it.
  props="--setenv=BASE_URL=http://$IP --setenv=BASE_URLS='$BASE_URLS' --setenv=PROFILE=$PROFILE --setenv=ONLY=$ONLY"
  props+=" --setenv=TOKENS=/root/stardust-bench-client/tokens.json --setenv=OUT=/root/stardust-bench-client/results/$LABEL"
  for v in HOLD RAMP_UP START STEP SEARCH WARMUP WARMUP_VUS; do [ -n "${!v:-}" ] && props+=" --setenv=$v=${!v}"; done
  [ -n "${REDLINE:-}" ] && props+=" --setenv=REDLINE='$REDLINE'"
  [ -n "${CONNECTIONS:-}" ] && props+=" --setenv=CONNECTIONS='$CONNECTIONS'"
  client "systemctl stop stardust-k6 2>/dev/null; systemctl reset-failed stardust-k6 2>/dev/null;
    systemd-run --unit=stardust-k6 --collect --quiet --property=LimitNOFILE=1048576 \
      --working-directory=/root/stardust-bench-client $props bash bench/score.sh"
  echo "== k6 on the client Linode $CLIENT_IP (Ctrl-C stops watching, not the run)"
  # ssh itself in the background (not a function), so that kill stops it.
  "${SSH[@]}" "root@$CLIENT_IP" 'journalctl -u stardust-k6 -f -o cat --since -10s' &
  FOLLOW=$!
  # Only systemd saying the unit is inactive ends the wait. An SSH failure (255)
  # means the client did not answer this time; k6 keeps running there.
  misses=0
  while :; do
    rc=0; client 'systemctl is-active --quiet stardust-k6' || rc=$?
    if [ "$rc" = 0 ]; then misses=0; sleep 10; continue; fi
    if [ "$rc" = 255 ]; then
      misses=$((misses + 1))
      echo "== the client did not answer over SSH ($misses); k6 keeps running there"
      [ "$misses" -lt 360 ] || die "the client has not answered for an hour"
      sleep 10; continue
    fi
    break
  done
  kill "$FOLLOW" 2>/dev/null || true
else
  AWAKE=(); command -v caffeinate >/dev/null && AWAKE=(caffeinate -is)
  env BASE_URL="http://$IP" BASE_URLS="$BASE_URLS" PROFILE="$PROFILE" ONLY="$ONLY" REDLINE="${REDLINE:-}" \
    CONNECTIONS="${CONNECTIONS:-}" TOKENS="$TOKENS" OUT="$OUT" \
    ${AWAKE[@]+"${AWAKE[@]}"} bash "$ROOT/bench/score.sh"
fi

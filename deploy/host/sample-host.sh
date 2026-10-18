#!/usr/bin/env bash
# Samples the server once per interval during a benchmark and prints CSV: CPU
# (user, system, iowait, softirq, steal, idle, in %), memory, the service's
# RSS, network and disk throughput, TCP sockets (IPv4, IPv6, orphaned, TIME_WAIT),
# unreclaimable kernel slab (where socket structures live) and load. Storage metadata and
# process I/O counters distinguish file growth from page rewrites. /proc reads
# use shell built-ins; file sizes use stat, without reading database contents.
# Rates use the measured interval. bench/report.py charts the samples.
#
#   sample-host.sh [interval_s] > metrics.csv    # runs until SIGTERM
set -u
IV="${1:-1}"
source "$(dirname "${BASH_SOURCE[0]}")/storage.sh"
NIC="$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route)"
UNIT=stardust-bench

pid() { systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0; }
cpu() { local _ u n s i w q sq st; read -r _ u n s i w q sq st _ < /proc/stat; echo "$((u + n)) $s $w $sq $st $i $((u + n + s + i + w + q + sq + st))"; }
net() {
  local line name rest rx tx
  while read -r line; do
    name="${line%%:*}"; name="${name// /}"
    if [ "$name" = "$NIC" ]; then rest="${line#*:}"; read -r rx _ _ _ _ _ _ _ tx _ <<< "$rest"; echo "$rx $tx"; return; fi
  done < /proc/net/dev
  echo "0 0"
}
disk() {
  local r=0 w=0 _a _b name rd wr
  while read -r _a _b name _ _ rd _ _ _ wr _; do
    [[ "$name" =~ ^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+)$ ]] && { r=$((r + rd)); w=$((w + wr)); }
  done < /proc/diskstats
  echo "$r $w"
}
mem() {
  local k v avail=0 cached=0 dirty=0 slab=0
  while read -r k v _; do
    case "$k" in MemAvailable:) avail=$v ;; Cached:) cached=$v ;; Dirty:) dirty=$v ;; SUnreclaim:) slab=$v ;; esac
  done < /proc/meminfo
  echo "$((avail / 1024)) $((cached / 1024)) $((dirty / 1024)) $((slab / 1024))"
}
rss() {
  local k v
  [ -r "/proc/$1/status" ] || { echo 0; return; }
  while read -r k v _; do [ "$k" = VmRSS: ] && { echo "$((v / 1024))"; return; }; done < "/proc/$1/status"
  echo 0
}
tcp() {
  local k a b c d e f six=0
  while read -r k a b _; do [ "$k" = TCP6: ] && six=$b; done < /proc/net/sockstat6
  while read -r k a b c d e f _; do [ "$k" = TCP: ] && { echo "$b $f $d $six"; return; }; done < /proc/net/sockstat
  echo "0 0 0 $six"   # IPv4 inuse, tw, orphan (both families), IPv6 inuse
}
pct() { printf '%d.%d' $(($1 * 1000 / $2 / 10)) $(($1 * 1000 / $2 % 10)); }

echo "t,cpu_user,cpu_system,cpu_iowait,cpu_softirq,cpu_steal,cpu_idle,mem_available_mb,mem_cached_mb,mem_dirty_mb,mem_slab_unreclaim_mb,svc_rss_mb,net_rx_kbps,net_tx_kbps,disk_read_kbs,disk_write_kbs,tcp_inuse,tcp_tw,tcp_orphan,tcp6_inuse,load1,$(storage_header)"
P="$(pid)" n=0
read -r cu cs cw cq cst ci ct <<< "$(cpu)"; read -r nr nt <<< "$(net)"; read -r dr dw <<< "$(disk)"
t0="${EPOCHREALTIME/./}"
while sleep "$IV"; do
  read -r u s w q st i tot <<< "$(cpu)"; read -r r x <<< "$(net)"; read -r rd wr <<< "$(disk)"
  t1="${EPOCHREALTIME/./}"; us=$((t1 - t0)); [ "$us" -gt 0 ] || us=1
  d=$((tot - ct)); [ "$d" -gt 0 ] || d=1
  n=$((n + 1)); [ $((n % 10)) = 0 ] && P="$(pid)"
  read -r avail cached dirty slab <<< "$(mem)"; read -r inuse tw orphan six <<< "$(tcp)"; read -r l1 _ < /proc/loadavg
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "${t1:0:-6}" \
    "$(pct $((u - cu)) $d)" "$(pct $((s - cs)) $d)" "$(pct $((w - cw)) $d)" "$(pct $((q - cq)) $d)" \
    "$(pct $((st - cst)) $d)" "$(pct $((i - ci)) $d)" "$avail" "$cached" "$dirty" "$slab" "$(rss "$P")" \
    $(((r - nr) * 8000 / us)) $(((x - nt) * 8000 / us)) $(((rd - dr) * 500000 / us)) $(((wr - dw) * 500000 / us)) \
    "$inuse" "$tw" "$orphan" "$six" "$l1" "$(storage_values "$P")"
  cu=$u cs=$s cw=$w cq=$q cst=$st ci=$i ct=$tot nr=$r nt=$x dr=$rd dw=$wr t0=$t1
done

#!/usr/bin/env bash
# Host settings for the bench box and the k6 machine.
#
#   sudo bash deploy/host/tune-host.sh --quiet   # stop background jobs (both profiles)
#   sudo bash deploy/host/tune-host.sh           # tuned profile: install the files below, apply, report
#   bash deploy/host/tune-host.sh --check        # report the effective values only
#   sudo bash deploy/host/tune-host.sh --revert  # remove the tuned files, then reboot
#
# The tuned profile raises descriptor limits, accept backlogs, ephemeral ports
# and socket memory. Stock (untuned) numbers compare with the challenge's
# published results; label every result "stock" or "tuned".
set -euo pipefail
SYSCTL=/etc/sysctl.d/90-stardust-bench.conf
LIMITS=/etc/security/limits.d/90-stardust-bench.conf
SYSTEMD=/etc/systemd/system.conf.d/90-stardust-bench.conf
DROPIN=/etc/systemd/system/stardust-bench.service.d/90-tuned.conf
CONNTRACK=/etc/sysctl.d/91-stardust-bench-conntrack.conf
# Background jobs that would take the one vCPU in the middle of a run. Stopping
# them changes no kernel setting; it only removes noise from a short-lived box.
UNITS=(apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service man-db.timer
  motd-news.timer fwupd-refresh.timer e2scrub_all.timer dpkg-db-backup.timer
  snapd.service snapd.socket irqbalance.service packagekit.service)

install_files() {
  install -d /etc/sysctl.d /etc/security/limits.d /etc/systemd/system.conf.d "$(dirname "$DROPIN")"
  cat > "$SYSCTL" <<'EOF'
# StardustDB Nanode and Linode 2GB Challenge, tuned profile (deploy/host/tune-host.sh).

# Descriptors. nr_open caps any RLIMIT_NOFILE; file-max caps the whole system.
# The server keeps sockets in io_uring's registered table, not the fd table,
# but the kernel and the load generator still need them.
fs.nr_open = 1048576
fs.file-max = 2097152

# io_uring for every process (Ubuntu 24.04 defaults to 0; hardened images use 2).
kernel.io_uring_disabled = 0

# Accept queue and SYN backlog for k6's ramp-up bursts. The server listens with
# a 65535 backlog and the kernel caps it at somaxconn.
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_syncookies = 1

# Ephemeral ports and TIME_WAIT: matters on the load generator, which opens one
# connection per virtual user (~64,500 per server address).
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 262144

# Keep-alive connections idle between requests; keep their window.
net.ipv4.tcp_slow_start_after_idle = 0

# Socket buffers: modest defaults so 100k+ sockets fit in 2 GB; autotuning
# still grows a busy socket up to the max.
net.ipv4.tcp_rmem = 4096 65536 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.optmem_max = 65536

# Memory. No swap. StardustDB maps its database file: write dirty pages back
# early so each commit's sync has little left to flush, and allow enough
# mappings for the engine's growth.
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.max_map_count = 262144
EOF
  # Login sessions (ssh, sudo -u bench, k6 from a shell).
  cat > "$LIMITS" <<'EOF'
*     soft  nofile  1048576
*     hard  nofile  1048576
root  soft  nofile  1048576
root  hard  nofile  1048576
*     soft  memlock unlimited
*     hard  memlock unlimited
EOF
  # Every systemd service. The challenge's box gives the server LimitNOFILE=65535;
  # with a 1,048,576 hard limit it runs one io_uring ring of 524,280 direct
  # descriptors instead of eight of 65,535.
  cat > "$SYSTEMD" <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitMEMLOCK=infinity
EOF
  cat > "$DROPIN" <<'EOF'
[Service]
LimitNOFILE=1048576
LimitMEMLOCK=infinity
EOF
  # The conntrack table exists only when netfilter tracks connections (ufw, docker).
  if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
    printf 'net.netfilter.nf_conntrack_max = 262144\n' > "$CONNTRACK"
  fi
}

check() {
  echo "== kernel $(uname -r)"
  for key in fs.nr_open fs.file-max kernel.io_uring_disabled net.core.somaxconn \
    net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem vm.dirty_background_ratio vm.dirty_ratio \
    net.netfilter.nf_conntrack_max; do
    printf '  %-34s %s\n' "$key" "$(sysctl -n "$key" 2>/dev/null | tr '\t' ' ' || echo '-')"
  done
  echo "== limits"
  printf '  %-34s %s / %s\n' "this shell nofile soft/hard" "$(ulimit -Sn)" "$(ulimit -Hn)"
  printf '  %-34s %s\n' "systemd DefaultLimitNOFILE" "$(systemctl show -p DefaultLimitNOFILE --value 2>/dev/null || echo '-')"
  if systemctl cat stardust-bench >/dev/null 2>&1; then
    printf '  %-34s %s\n' "stardust-bench LimitNOFILE" "$(systemctl show stardust-bench -p LimitNOFILE --value)"
  fi
}

present() { [ -n "$(systemctl list-unit-files --no-legend "$1" 2>/dev/null)" ]; }

quiet() {
  # A fresh Ubuntu image runs unattended-upgrades at first boot: let it finish
  # rather than interrupt dpkg (up to 15 minutes). Match unattended-upgrade
  # itself, not the unattended-upgrade-shutdown helper that waits forever.
  for _ in $(seq 180); do
    pgrep -f 'unattended-upgrade( |$)|apt-get|apt.systemd.daily|dpkg ' >/dev/null || break
    sleep 5
  done
  local stopped=() u
  for u in "${UNITS[@]}"; do
    if present "$u"; then systemctl disable --now "$u" >/dev/null 2>&1 && stopped+=("${u%.*}"); fi
  done
  echo "stopped: ${stopped[*]:-nothing}"
}

[ "$(uname -s)" = Linux ] || { echo "tune-host.sh is for the Linux bench box"; exit 1; }
case "${1:-}" in
  --check) check; exit 0 ;;
  --quiet|--revert|"") [ "$(id -u)" = 0 ] || { echo "run as root: sudo bash $0 $*"; exit 1; } ;;
  *) echo "usage: $0 [--quiet|--check|--revert]"; exit 2 ;;
esac
case "${1:-}" in
  --quiet) quiet; exit 0 ;;
  --revert)
    rm -f "$SYSCTL" "$LIMITS" "$SYSTEMD" "$DROPIN" "$CONNTRACK"
    systemctl daemon-reexec && systemctl daemon-reload
    echo "removed; reboot to restore every kernel default"; exit 0 ;;
esac
install_files
# Some keys are read-only inside containers (fs.*, vm.*): report, don't stop.
sysctl --system >/dev/null 2>&1 || echo "== warning: some sysctl keys were not applied (see --check)"
systemctl daemon-reexec   # applies DefaultLimitNOFILE to services started from now on
systemctl daemon-reload   # picks up the stardust-bench drop-in
check
echo "== applied; log in again for the new shell limits, restart services for theirs"

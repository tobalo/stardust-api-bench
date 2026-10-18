#!/usr/bin/env bash
# Linux metadata only: never scan, sync or open the live database through Stardust.
# Source from sample-host.sh, or run `bash storage.sh <phase>` for a CSV snapshot.
# STARDUST_PATH / STARDUST_SEED_PATH override the deployed file locations.

storage_header() {
  printf '%s' 'db_id,db_apparent_bytes,db_allocated_bytes,seed_apparent_bytes,seed_allocated_bytes,fs_available_bytes,svc_pid,svc_start_ticks,svc_write_bytes,svc_cancelled_write_bytes,svc_peak_rss_bytes'
}

storage_values() {
  local pid=${1:-0} db=${STARDUST_PATH:-/var/lib/stardust-bench/run/feed.stardust}
  local seed=${STARDUST_SEED_PATH:-/var/lib/stardust-bench/seed/feed.stardust}
  local id='' size='' blocks='' unit='' allocated='' seed_size='' seed_allocated=''
  local available='' start='' written='' cancelled='' peak='' k v line
  local fields=()
  if read -r id size blocks unit < <(stat -Lc '%d:%i %s %b %B' -- "$db" 2>/dev/null); then
    allocated=$((blocks * unit))
  fi
  if read -r seed_size blocks unit < <(stat -Lc '%s %b %B' -- "$seed" 2>/dev/null); then
    seed_allocated=$((blocks * unit))
  fi
  if read -r blocks unit < <(stat -f -c '%a %S' -- "$(dirname "$db")" 2>/dev/null); then
    available=$((blocks * unit))
  fi
  # starttime distinguishes PID reuse; missing counters stay blank, never zero.
  if [ "$pid" -gt 0 ] && [ -r "/proc/$pid/stat" ]; then
    if read -r line < "/proc/$pid/stat" 2>/dev/null; then
      read -r -a fields <<< "${line##*) }"
      start=${fields[19]:-}
    fi
    if [ -r "/proc/$pid/io" ]; then
      while read -r k v; do
        case "$k" in write_bytes:) written=$v ;; cancelled_write_bytes:) cancelled=$v ;; esac
      done < "/proc/$pid/io" 2>/dev/null || true
    fi
    if [ -r "/proc/$pid/status" ]; then
      while read -r k v _; do [ "$k" != VmHWM: ] || peak=$((v * 1024)); done < "/proc/$pid/status" 2>/dev/null || true
    fi
    if ! read -r line < "/proc/$pid/stat" 2>/dev/null; then
      start='' written='' cancelled='' peak=''
    else
      read -r -a fields <<< "${line##*) }"
      [ "${fields[19]:-}" = "$start" ] || { start='' written='' cancelled='' peak=''; }
    fi
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' \
    "$id" "$size" "$allocated" "$seed_size" "$seed_allocated" "$available" \
    "$pid" "$start" "$written" "$cancelled" "$peak"
}

# bash -s (SSH stdin) has no BASH_SOURCE entry; sourcing from the sampler does.
if [[ ${BASH_SOURCE[0]:-$0} = "$0" ]]; then
  set -u
  phase=${1:-snapshot}
  [[ "$phase" =~ ^[a-z_]+$ ]] || { echo 'phase must contain only lowercase letters and underscores' >&2; exit 2; }
  pid=$(systemctl show -p MainPID --value stardust-bench 2>/dev/null) || pid=0
  printf 'phase,t,%s\n' "$(storage_header)"
  printf '%s,%s,%s\n' "$phase" "$(date +%s)" "$(storage_values "${pid:-0}")"
fi

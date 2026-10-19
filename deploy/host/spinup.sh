#!/usr/bin/env bash
# Deploys the benchmark server to a Linux box (Ubuntu 22.04/24.04, x86_64 or
# arm64) over SSH, ready to benchmark:
#   1. checks the box: kernel >= 6.1, io_uring enabled, disk;
#   2. uploads the source, the StardustDB bundle for its architecture, the
#      seed (zstd: ~210 MiB, not 3.6 GB) and the license (over ssh stdin, 0600);
#   3. builds the server on the box (Rust 1.94.0, target-cpu=native, StardustDB
#      linked statically; a temporary swapfile covers 1 GB boxes);
#   4. installs the systemd service and the host sampler, turns swap off, stops
#      background jobs, and applies the stock or tuned profile;
#   5. runs the 42 API checks against the io_uring server, then restarts it on
#      a fresh database.
#
#   bash deploy/host/spinup.sh root@203.0.113.7           # stock: the challenge box's settings
#   bash deploy/host/spinup.sh --tuned root@203.0.113.7   # + deploy/host/tune-host.sh
#
# Env: SEED (default seed/feed.stardust.zst), SSH_KEY and KNOWN_HOSTS (a deploy
# key), LICENSE_FILE (default ~/.config/stardustdb/stardust.license). Needs root
# or passwordless sudo on the box.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LICENSE_FILE="${LICENSE_FILE:-$HOME/.config/stardustdb/stardust.license}"
SEED="${SEED:-$ROOT/seed/feed.stardust.zst}"
STAGE=stardust-bench-staging   # in the ssh user's home; reruns send only changes
die() { echo "spinup: $*" >&2; exit 1; }

TUNED=0 TEST=1
while [ $# -gt 1 ]; do
  case "$1" in
    --tuned) TUNED=1 ;; --skip-test) TEST=0 ;; *) die "unknown option $1" ;;
  esac
  shift
done
[ $# = 1 ] && [ "${1#-}" = "$1" ] || die "usage: spinup.sh [--tuned] [--skip-test] user@host"
TARGET="$1"
PROFILE=$([ $TUNED = 1 ] && echo tuned || echo stock)
[ -s "$LICENSE_FILE" ] || die "no license at $LICENSE_FILE (set LICENSE_FILE)"
[ -s "$SEED" ] || die "no $SEED: make seed"

SOCK="/tmp/sd-spinup-$$"
SSH_OPTS=(-o ControlMaster=auto -o ControlPath="$SOCK" -o ControlPersist=300 -o ServerAliveInterval=30)
[ -n "${SSH_KEY:-}" ] && SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
[ -n "${KNOWN_HOSTS:-}" ] && SSH_OPTS+=(-o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new)
remote() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
trap 'ssh -o ControlPath="$SOCK" -O exit "$TARGET" 2>/dev/null || true' EXIT

echo "== $TARGET"
SUDO="$(remote 'if [ "$(id -u)" = 0 ]; then echo; elif sudo -n true 2>/dev/null; then echo sudo; else echo NO; fi')"
[ "$SUDO" != NO ] || die "$TARGET needs root or passwordless sudo"
remote 'set -e
  arch=$(uname -m); kernel=$(uname -r)
  case "$arch" in x86_64|aarch64) ;; *) echo "   $arch: builds exist for x86_64 and aarch64"; exit 1 ;; esac
  major=${kernel%%.*}; rest=${kernel#*.}; minor=${rest%%.*}
  [ "$major" -gt 6 ] || { [ "$major" = 6 ] && [ "$minor" -ge 1 ]; } || { echo "   kernel $kernel: io_uring needs 6.1+"; exit 1; }
  disabled=$(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || echo 0)
  [ "$disabled" = 0 ] || echo "   warning: kernel.io_uring_disabled=$disabled (the tuned profile sets 0)"
  free_gb=$(df -BG --output=avail /var/lib | tail -1 | tr -dc 0-9)
  [ "$free_gb" -ge 9 ] || { echo "   /var/lib has ${free_gb}G free; need 9G (seed and the run copy, 3.6 GB each)"; exit 1; }
  . /etc/os-release 2>/dev/null || true
  echo "   ${PRETTY_NAME:-Linux} $kernel $arch, $(nproc) CPU, $(free -m | awk "/^Mem:/{print \$2}") MiB RAM, ${free_gb}G free"'
case "$(remote 'uname -m')" in x86_64) ARCH=amd64 ;; *) ARCH=arm64 ;; esac
BUNDLE="$ROOT/third_party/stardust-linux_$ARCH"
[ -d "$BUNDLE" ] || die "no StardustDB bundle for linux $ARCH: bash deploy/bundle.sh <stardust-...-linux-$ARCH.zip>"
SEED_SUM="$( (sha256sum 2>/dev/null || shasum -a 256) < "$SEED" | cut -d' ' -f1)"
echo "   $(du -h "$SEED" | cut -f1) compressed seed, StardustDB $(grep -o '"version": *"[^"]*"' "$BUNDLE/manifest.json" | cut -d'"' -f4) linux $ARCH; profile $PROFILE, :80 direct"

echo "== upload (rsync; reruns send only changes)"
remote "command -v rsync >/dev/null && command -v zstd >/dev/null || { $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 update -qq && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y -qq rsync zstd >/dev/null; }"
remote "mkdir -p ~/$STAGE/bench ~/$STAGE/host ~/$STAGE/bin ~/$STAGE/src/third_party"
RSYNC=(rsync -az --partial -e "ssh ${SSH_OPTS[*]}")
"${RSYNC[@]}" --progress "$SEED" "$TARGET:$STAGE/feed.stardust.zst"
UPSTREAM="$(bash "$ROOT/bench/upstream.sh")"   # the challenge's 42 checks, pinned
"${RSYNC[@]}" --delete "$UPSTREAM/test/test.sh" "$UPSTREAM/test/golden" "$TARGET:$STAGE/bench/"
"${RSYNC[@]}" --delete "$ROOT/deploy/host/" "$TARGET:$STAGE/host/"
"${RSYNC[@]}" --delete --exclude target/ "$ROOT/server/" "$TARGET:$STAGE/src/server/"
"${RSYNC[@]}" --delete "$BUNDLE/" "$TARGET:$STAGE/src/third_party/stardust/"

echo "== build on the box"
remote "set -e; S=$SUDO; cd ~/$STAGE/src/server
  if [ ! -x /opt/twelve-rust/cargo/bin/cargo ]; then   # Rust 1.94.0, pinned as in PR #19
    \$S apt-get -o DPkg::Lock::Timeout=900 update -qq
    \$S env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y -qq build-essential curl ca-certificates >/dev/null
    curl -fsSL https://sh.rustup.rs -o /tmp/rustup.sh
    \$S env RUSTUP_HOME=/opt/twelve-rust/rustup CARGO_HOME=/opt/twelve-rust/cargo \\
      sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.94.0 --no-modify-path >/dev/null 2>&1
    \$S chmod -R a+rX /opt/twelve-rust
  fi
  # Linking with fat LTO needs more than 1 GB: a temporary swapfile, removed after.
  swap=
  if [ \$(awk '/^MemTotal/{print int(\$2/1024)}' /proc/meminfo) -lt 3000 ] && [ -z \"\$(swapon --noheadings)\" ]; then
    \$S fallocate -l 3G /var/tmp/build.swap && \$S chmod 600 /var/tmp/build.swap && \$S mkswap -q /var/tmp/build.swap && \$S swapon /var/tmp/build.swap && swap=1
  fi
  start=\$(date +%s); rc=0
  bash build.sh -q > build.log 2>&1 || rc=\$?
  if [ -n \"\$swap\" ]; then \$S swapoff /var/tmp/build.swap; \$S rm -f /var/tmp/build.swap; fi
  if [ \$rc != 0 ]; then tail -30 build.log; exit \$rc; fi
  install -m 0755 target/release/stardust-uring target/release/import ~/$STAGE/bin/
  echo \"   built in \$(( \$(date +%s) - start )) s: \$(ls -l target/release/stardust-uring | awk '{print \$5}') bytes, \$(ldd target/release/stardust-uring | grep -c stardust) shared StardustDB libraries\"" \
  || die "the build failed on $TARGET"

echo "== install"
remote "set -e; S=$SUDO
  \$S systemctl stop stardust-bench 2>/dev/null || true
  id bench >/dev/null 2>&1 || \$S useradd --system --home-dir /var/lib/stardust-bench --create-home --shell /usr/sbin/nologin bench
  \$S install -d -o bench -g bench -m 0750 /var/lib/stardust-bench /var/lib/stardust-bench/seed /var/lib/stardust-bench/run
  \$S install -d -m 0755 /opt/stardust-bench/bin
  \$S install -m 0755 ~/$STAGE/bin/stardust-uring ~/$STAGE/bin/import /opt/stardust-bench/bin/
  \$S install -m 0755 ~/$STAGE/host/sample-host.sh /opt/stardust-bench/bin/sample-host
  \$S install -m 0644 ~/$STAGE/host/storage.sh /opt/stardust-bench/bin/storage.sh
  dst=/var/lib/stardust-bench/seed/feed.stardust
  # Unpack the seed only when it changed: ~210 MiB in, 3.6 GB out (sparse).
  if [ \"\$(\$S cat \$dst.sha256 2>/dev/null)\" != $SEED_SUM ] || [ ! -s \$dst ]; then
    \$S zstd -d -q -f --sparse ~/$STAGE/feed.stardust.zst -o \$dst
    echo $SEED_SUM | \$S tee \$dst.sha256 >/dev/null
  fi
  \$S chown bench:bench \$dst && \$S chmod 0440 \$dst
  \$S install -m 0644 ~/$STAGE/host/stardust-bench.service /etc/systemd/system/stardust-bench.service"
# The license: stdin only, created 0600 for the service user.
remote "set -e; umask 077; S=$SUDO
  \$S install -d -o bench -g bench -m 0700 /var/lib/stardust-bench/.config /var/lib/stardust-bench/.config/stardustdb
  \$S tee /var/lib/stardust-bench/.config/stardustdb/stardust.license >/dev/null
  \$S chown bench:bench /var/lib/stardust-bench/.config/stardustdb/stardust.license
  \$S chmod 0600 /var/lib/stardust-bench/.config/stardustdb/stardust.license" < "$LICENSE_FILE"
# HOST=:: serves IPv4 and IPv6 on one socket where the box has IPv6 (bench/connections.js uses both).
HOST="$(remote 'grep -q . /proc/net/if_inet6 2>/dev/null && echo :: || echo 0.0.0.0')"
printf 'STARDUST_PATH=/var/lib/stardust-bench/run/feed.stardust\nJWT_SECRET=twelve-dollar-challenge\nHOST=%s\nPORT=80\n' "$HOST" \
  | remote "umask 077; $SUDO tee /etc/stardust-bench.env >/dev/null"
AS_BENCH="$([ -z "$SUDO" ] && echo "runuser -u bench --" || echo "sudo -u bench")"
remote "$AS_BENCH env HOME=/var/lib/stardust-bench /opt/stardust-bench/bin/stardust-uring --license-check" 2>&1 \
  | sed 's/^/   /' || die "the license does not activate on $TARGET"
remote "$SUDO bash ~/$STAGE/host/tune-host.sh --quiet" | sed 's/^/   /'
# No swap, as on the challenge box: a 1 GB server must fit in RAM or fail.
remote "set -e; S=$SUDO; \$S swapoff -a; \$S sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# stardust-bench: /' /etc/fstab
  echo \"   swap: off (\$(free -m | awk '/^Swap:/{print \$2}') MB)\""

echo "== profile: $PROFILE"
if [ $TUNED = 1 ]; then
  remote "$SUDO bash ~/$STAGE/host/tune-host.sh" | sed 's/^/   /'
elif remote "[ -e /etc/sysctl.d/90-stardust-bench.conf ]"; then
  remote "$SUDO bash ~/$STAGE/host/tune-host.sh --revert" >/dev/null
  echo "   removed the tuned files; reboot before a stock run to restore every kernel default"
fi

start() {
  remote "set -e; $SUDO systemctl daemon-reload; $SUDO systemctl enable --quiet stardust-bench; $SUDO systemctl restart stardust-bench
    for _ in \$(seq 120); do curl -sf http://127.0.0.1/health >/dev/null && exit 0; sleep 1; done
    echo 'no healthy /health after 120 s'; $SUDO journalctl -u stardust-bench -n 40 --no-pager; exit 1"
}
echo "== start"
start
remote "$SUDO journalctl -u stardust-bench -n 20 --no-pager -o cat | grep listening | tail -1" | sed 's/^/   /'

if [ $TEST = 1 ]; then
  echo "== 42 API checks against the io_uring server"
  remote "command -v jq >/dev/null && command -v openssl >/dev/null && command -v curl >/dev/null || \
    { $SUDO apt-get -o DPkg::Lock::Timeout=900 update -qq && $SUDO DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 install -y -qq curl jq openssl >/dev/null; }"
  if ! out="$(remote "bash ~/$STAGE/bench/test.sh http://127.0.0.1:80" 2>&1)"; then
    echo "$out" | grep -E 'FAIL|want|got|passed=' | sed 's/^/   /'
    die "checks failed; server log: ssh $TARGET journalctl -u stardust-bench"
  fi
  echo "$out" | sed 's/^/   /'
  echo "== restart on a fresh database"
  start
fi
echo "== ready: http://${TARGET#*@} ($PROFILE, LimitNOFILE $(remote "systemctl show stardust-bench -p LimitNOFILE --value"))"

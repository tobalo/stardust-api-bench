#!/usr/bin/env bash
# From nothing to a server ready to benchmark, in one command, and back:
#   1. the seed: built here once (seed/make-seed.sh: the import needs ~8 GB,
#      more than a Nanode has; the file is portable across OS and architecture)
#      and compressed to ~210 MiB for the upload;
#   2. OpenTofu/Terraform (main.tf): the server in us-central (Dallas), Ubuntu
#      24.04, no swap, behind a Cloud Firewall that admits only this machine and
#      the k6 client;
#   3. deploys it (deploy/host/spinup.sh): builds the server on the box from source
#      and the StardustDB linux x86_64 bundle, installs the seed, the license and a
#      systemd service serving :80 directly; runs the 42 checks and restarts it on a
#      fresh database;
#   4. prepares the k6 client: k6, the tuned profile, the load tests and the tokens.
# It ends by printing the address to benchmark.
#
#   bash deploy/linode/up.sh                         # Nanode 1 GB (g6-nanode-1)
#   bash deploy/linode/up.sh --type g6-standard-1    # Linode 2 GB: replaces the server
#   bash deploy/linode/up.sh --stock                 # challenge-box settings, no host tuning
#   bash deploy/linode/up.sh --client [<plan>]       # + a k6 client Linode (default g6-dedicated-4); --no-client
#   bash deploy/linode/up.sh --down [--yes]          # destroy the server, the client and the firewalls
#
# Needs the StardustDB bundles (deploy/bundle.sh), the license, node, OpenTofu or
# Terraform, zstd and jq, and a Linode API token (Linodes and Firewalls read/write):
# LINODE_API_TOKEN=... in the repo's .env, $LINODE_TOKEN or ~/.config/linode/token.
# Reruns converge: nothing is rebuilt or recreated that is already right.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LICENSE_FILE="${LICENSE_FILE:-$HOME/.config/stardustdb/stardust.license}"
VARS="$HERE/deploy.auto.tfvars.json"   # git-ignored: this machine's key, address and plan
KEY="$HERE/.ssh/id_ed25519"
die() { echo "up: $*" >&2; exit 1; }
usage() { sed -n '/^#   bash deploy/p' "$0" | sed 's/^# //'; exit 2; }

# The Linode API token, exported as LINODE_TOKEN for the provider and never
# printed: $LINODE_TOKEN, $LINODE_API_TOKEN, a LINODE_(API_)TOKEN= line in the
# repo's .env (git-ignored), then ~/.config/linode/token ($LINODE_TOKEN_FILE).
token="${LINODE_TOKEN:-${LINODE_API_TOKEN:-}}"
TOKEN_FILE="${LINODE_TOKEN_FILE:-$HOME/.config/linode/token}"
if [ -z "$token" ] && [ -f "$ROOT/.env" ]; then
  token="$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?LINODE_(API_)?TOKEN[[:space:]]*=[[:space:]]*//p' "$ROOT/.env" \
    | tail -1 | tr -d "\"'[:space:]")"
fi
[ -z "$token" ] && [ -s "$TOKEN_FILE" ] && token="$(tr -d '[:space:]' < "$TOKEN_FILE")"
[ -n "$token" ] && export LINODE_TOKEN="$token"
unset token

TYPE="" TUNED=1 CLIENT="-" DOWN=0 YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="${2:?--type needs a plan, e.g. g6-standard-1}"; shift ;;
    --stock) TUNED=0 ;;
    --client) CLIENT=g6-dedicated-4
      case "${2:-}" in g6-*) CLIENT="$2"; shift ;; esac ;;
    --no-client) CLIENT="" ;;
    --down) DOWN=1 ;;
    --yes) YES=1 ;;
    -h|--help) usage ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

# The k6 client Linode: k6, jq and curl; the tuned profile (descriptors and
# ephemeral ports for 100k+ connections) with background jobs stopped; and the
# load tests, score script and tokens.
client_setup() {
  local client="$1" k6=2.3.0 upstream
  local cssh=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$HERE/.ssh/known_hosts" -o ServerAliveInterval=30 -o ConnectTimeout=10)
  local rs=(rsync -az -e "${cssh[*]}")
  echo "== client $client"
  "${cssh[@]}" "$client" 'command -v rsync >/dev/null && command -v jq >/dev/null || { export DEBIAN_FRONTEND=noninteractive;
    apt-get -o DPkg::Lock::Timeout=900 update -qq && apt-get -o DPkg::Lock::Timeout=900 install -y -qq rsync jq curl >/dev/null; }'
  upstream="$(bash "$ROOT/bench/upstream.sh")"   # the challenge's load test, pinned
  "${cssh[@]}" "$client" 'mkdir -p stardust-bench-client/bench/.upstream/bench stardust-bench-client/host'
  "${rs[@]}" "$ROOT/bench/score.sh" "$ROOT/bench/connections.js" "$client:stardust-bench-client/bench/"
  "${rs[@]}" "$upstream/bench/load.js" "$client:stardust-bench-client/bench/.upstream/bench/"
  "${rs[@]}" --delete "$ROOT/deploy/host/" "$client:stardust-bench-client/host/"
  "${rs[@]}" "$ROOT/seed/tokens.json" "$client:stardust-bench-client/tokens.json"
  "${cssh[@]}" "$client" "k6 version 2>/dev/null | grep -q 'v$k6' || { curl -fsSL https://github.com/grafana/k6/releases/download/v$k6/k6-v$k6-linux-amd64.tar.gz | tar -xz -C /tmp && install -m 0755 /tmp/k6-v$k6-linux-amd64/k6 /usr/local/bin/k6; }"
  "${cssh[@]}" "$client" 'bash stardust-bench-client/host/tune-host.sh >/dev/null && bash stardust-bench-client/host/tune-host.sh --quiet' | sed 's/^/   /'
  "${cssh[@]}" "$client" 'echo "   $(k6 version | head -1 | cut -d" " -f1-2), $(nproc) CPU, $(free -m | awk "/^Mem:/{print \$2}") MiB RAM, ports $(sysctl -n net.ipv4.ip_local_port_range | tr "\t" "-")"'
}

SPINUP=()
[ $TUNED = 1 ] && SPINUP+=(--tuned)
PROFILE="$([ $TUNED = 1 ] && echo tuned || echo stock)"

TF="$(command -v tofu || command -v terraform || true)"
[ -n "$TF" ] || die "install OpenTofu (brew install opentofu) or Terraform"
if [ $DOWN = 1 ]; then   # results stay in bench/results/
  [ -n "${LINODE_TOKEN:-}" ] || die "no Linode API token: add LINODE_API_TOKEN=... to .env (git-ignored) or export LINODE_TOKEN"
  exec "$TF" -chdir="$HERE" destroy -input=false $([ $YES = 1 ] && echo -auto-approve)
fi
# The whole deploy log, kept for the next bench session (bench.sh copies it in as deploy.log).
exec > >(tee "$HERE/up.log") 2>&1
for tool in zstd jq curl rsync; do command -v "$tool" >/dev/null || die "install $tool"; done
[ -n "${LINODE_TOKEN:-}" ] || die "no Linode API token: add LINODE_API_TOKEN=... to .env (git-ignored) or export LINODE_TOKEN"
[ -d "$ROOT/third_party/stardust-linux_amd64" ] || [ -d "$ROOT/third_party/stardust-linux_x86_64" ] \
  || die "no linux x86_64 StardustDB bundle: download it from StardustDB, then bash deploy/bundle.sh <zip>"
[ -s "$LICENSE_FILE" ] || die "no license at $LICENSE_FILE (set LICENSE_FILE)"

SEED="$ROOT/seed/feed.stardust"
if [ ! -s "$SEED" ] || [ ! -s "$ROOT/seed/tokens.json" ]; then
  echo "== seed: building it here (~90 s, ~8 GB RAM)"
  bash "$ROOT/seed/make-seed.sh" 2>&1 | grep -E 'rows|tokens|posts|likes|imported|OK' | sed 's/^/   /'
fi
if [ ! -s "$SEED.zst" ] || [ "$SEED" -nt "$SEED.zst" ]; then
  zstd -T0 -3 -q -f "$SEED" -o "$SEED.zst"
fi
echo "== seed: $(du -h "$SEED.zst" | cut -f1) compressed ($(du -h "$SEED" | cut -f1) on disk), $(jq length "$ROOT/seed/tokens.json") tokens"

mkdir -p "$HERE/.ssh"
[ -s "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C stardust-api-bench -f "$KEY"
OPERATOR="${OPERATOR_CIDR:-$(curl -fsS -m 10 https://api.ipify.org)/32}"
PREVIOUS_TYPE="$(jq -r '.bench_type // empty' "$VARS" 2>/dev/null || true)"
TYPE="${TYPE:-${PREVIOUS_TYPE:-g6-nanode-1}}"
[ "$CLIENT" = "-" ] && CLIENT="$(jq -r '.client_type // empty' "$VARS" 2>/dev/null || true)"
jq -n --arg key "$(cat "$KEY.pub")" --arg op "$OPERATOR" --arg type "$TYPE" --arg client "$CLIENT" \
  '{ssh_public_key: $key, operator_cidrs: [$op], bench_type: $type, client_type: $client}' > "$VARS"

echo "== provision: $TYPE in us-central${CLIENT:+, k6 client $CLIENT}; firewall open to $OPERATOR"
"$TF" -chdir="$HERE" init -input=false >/dev/null
REPLACE=()
CURRENT="$("$TF" -chdir="$HERE" output -raw bench_type 2>/dev/null || true)"
if [ -n "$CURRENT" ] && [ "$CURRENT" != "$TYPE" ]; then
  echo "   $CURRENT -> $TYPE: replacing the server (a clean box, not a resize)"
  REPLACE=(-replace=linode_instance.bench)
fi
"$TF" -chdir="$HERE" apply -input=false -auto-approve ${REPLACE[@]+"${REPLACE[@]}"} \
  | grep -E 'Apply complete|Creation complete|Destruction complete|Modifications complete|Error' || true
IP="$("$TF" -chdir="$HERE" output -raw bench_ip)"
[ -n "$IP" ] || die "no bench_ip in the Terraform outputs"

echo "== wait for SSH on $IP"
ssh-keygen -f "$HERE/.ssh/known_hosts" -R "$IP" >/dev/null 2>&1 || true
SSH=(ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$HERE/.ssh/known_hosts" -o ConnectTimeout=5 -o BatchMode=yes)
for i in $(seq 60); do
  "${SSH[@]}" "root@$IP" true 2>/dev/null && break
  [ "$i" = 60 ] && die "no SSH on $IP after 5 minutes"
  sleep 5
done

SSH_KEY="$KEY" KNOWN_HOSTS="$HERE/.ssh/known_hosts" SEED="$SEED.zst" \
  bash "$ROOT/deploy/host/spinup.sh" ${SPINUP[@]+"${SPINUP[@]}"} "root@$IP"

# The routed IPv6 /64 (main.tf): eight more server addresses for make connections.
# They live until the next reboot; up.sh adds them again on every run.
EXTRA=($("$TF" -chdir="$HERE" output -json bench_ipv6_extra 2>/dev/null | jq -r '.[]?' || true))
if [ ${#EXTRA[@]} -gt 0 ]; then
  "${SSH[@]}" "root@$IP" "dev=\$(ip -6 route show default | awk '{print \$5; exit}')
    for a in ${EXTRA[*]}; do ip -6 addr replace \$a/64 dev \$dev nodad; done
    echo \"== IPv6 range: ${#EXTRA[@]} more server addresses on \$dev (${EXTRA[0]} ...)\""
fi

CLIENT_IP="$("$TF" -chdir="$HERE" output -raw client_ip 2>/dev/null || true)"
if [ -n "$CLIENT_IP" ]; then
  echo "== wait for SSH on the k6 client $CLIENT_IP"
  # Linode reuses addresses: a new client can have an old server's IP and host key.
  ssh-keygen -f "$HERE/.ssh/known_hosts" -R "$CLIENT_IP" >/dev/null 2>&1 || true
  for i in $(seq 60); do
    "${SSH[@]}" "root@$CLIENT_IP" true 2>/dev/null && break
    [ "$i" = 60 ] && die "no SSH on $CLIENT_IP after 5 minutes"
    sleep 5
  done
  client_setup "root@$CLIENT_IP"
fi
CLIENT_LINE="$([ -n "$CLIENT_IP" ] && echo "the k6 client Linode $CLIENT_IP ($CLIENT)" || echo "this machine")"

cat <<DONE

== ready to benchmark: http://$IP   ($TYPE, $PROFILE, systemd, direct :80)
   health:         $(curl -fsS -m 10 "http://$IP/health" || echo "not reachable from here")
   load client:    $CLIENT_LINE
   score it:       bash deploy/linode/bench.sh             (the challenge procedure)
   one load test:  bash deploy/linode/bench.sh --vus 1000
   ssh:            ssh -i deploy/linode/.ssh/id_ed25519 root@$IP
   tear down:      make down
DONE

#!/bin/bash
# bash-scripts/upsert-github-runner.sh
# Idempotent deploy/update of a Dockerized GitHub self-hosted runner.
# GCP free-tier caps: 0.50 CPU, 256 MiB RAM.

set -euo pipefail

# GCP free-tier VM is IPv6-only; GHCR native IPv6 can time out.
# Route GHCR hostnames through GCP DNS64/NAT64 (well-known prefix 64:ff9b::/96).

NAT64_PREFIX="64:ff9b::"
GHCR_HOSTS=(ghcr.io pkg-containers.githubusercontent.com)

ghcr_nat64_addr() {
  local host="$1" ipv4 a b c d
  ipv4=$(curl -fsSL --max-time 10 --retry 2 "https://dns.google/resolve?name=${host}&type=A" | grep -o '"data":"[^"]*"' | head -1 | grep -oE '[0-9.]+')
  [ -n "$ipv4" ] || ipv4=$(getent ahostsv4 "$host" | awk 'NR==1 {print $1; exit}')
  if [ -z "$ipv4" ]; then
    case "$host" in
      ghcr.io) ipv4=20.26.156.211 ;;
      pkg-containers.githubusercontent.com) ipv4=185.199.109.154 ;;
    esac
  fi
  [ -n "$ipv4" ] || return 1
  IFS=. read -r a b c d <<< "$ipv4"
  printf '%s%02x%02x:%02x%02x\n' "$NAT64_PREFIX" "$a" "$b" "$c" "$d"
}
CONTAINER_NAME="${GH_RUNNER_CONTAINER_NAME:-github-runner}"
IMAGE="ghcr.io/youssefbrr/self-hosted-runner:latest"
RUNNER_CPU="0.50"
RUNNER_MEMORY="256m"

REPO="${GH_RUNNER_REPO:-}"
REG_TOKEN="${GH_RUNNER_REG_TOKEN:-}"
NAME="${GH_RUNNER_NAME:-${TS_HOSTNAME:-gcp-free-tier-vm}}"
LABELS="${GH_RUNNER_LABELS:-self-hosted,linux,x64,gcp-free-tier}"
RUNNER_GROUP="${GH_RUNNER_GROUP:-}"
WORK_DIR="${GH_RUNNER_WORK_DIR:-_work}"
EPHEMERAL="${GH_RUNNER_EPHEMERAL:-false}"
DISABLE_AUTO_UPDATE="${GH_RUNNER_DISABLE_AUTO_UPDATE:-true}"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

status "upsert github runner start"

step "checking required env"
missing=()
[ -z "$REPO" ]       && missing+=("GH_RUNNER_REPO")
[ -z "$REG_TOKEN" ]  && missing+=("GH_RUNNER_REG_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  fail "missing required env: ${missing[*]}"
fi
ok "env ok"

step "removing existing runner container"
docker stop --time 30 "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
ok "cleanup done"

step "checking docker daemon"
docker info >/dev/null 2>&1 || fail "docker daemon is not available"
ok "docker ready"

step "forcing ghcr.io through NAT64"
for host in "${GHCR_HOSTS[@]}"; do
  addr=$(ghcr_nat64_addr "$host" 2>/dev/null || true)
  if [ -z "$addr" ]; then
    warn "could not synthesize NAT64 address for ${host}; leaving resolver to handle it"
    continue
  fi
  if grep -qE "^${NAT64_PREFIX}[0-9a-f:]+[[:space:]]+${host}([[:space:]]|$)" /etc/hosts; then
    ok "already mapped ${host}"
    continue
  fi
  echo "${addr} ${host} # GHCR via NAT64" | sudo tee -a /etc/hosts >/dev/null \
    || warn "failed to update /etc/hosts for ${host}"
  ok "mapped ${host} -> ${addr}"
done

step "pulling latest ${IMAGE}"
PULL_LOG=$(mktemp)
PULL_OK=0
for attempt in 1 2 3; do
  if docker pull "$IMAGE" >"$PULL_LOG" 2>&1; then
    PULL_OK=1
    break
  fi
  warn "pull attempt ${attempt} failed"
  sleep 5
done
if [ "$PULL_OK" -ne 1 ]; then
  warn "docker pull output:"
  cat "$PULL_LOG" >&2
  rm -f "$PULL_LOG"
  fail "failed to pull runner image"
fi
rm -f "$PULL_LOG"
ok "image pulled"

step "starting runner container"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always \
  --network=host \
  --cpus "$RUNNER_CPU" \
  --memory "$RUNNER_MEMORY" \
  --memory-swap "$RUNNER_MEMORY" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e REPO="$REPO" \
  -e REG_TOKEN="$REG_TOKEN" \
  -e NAME="$NAME" \
  -e LABELS="$LABELS" \
  -e RUNNER_GROUP="$RUNNER_GROUP" \
  -e WORK_DIR="$WORK_DIR" \
  -e EPHEMERAL="$EPHEMERAL" \
  -e DISABLE_AUTO_UPDATE="$DISABLE_AUTO_UPDATE" \
  --log-driver json-file \
  --log-opt max-size=5m \
  --log-opt max-file=2 \
  "$IMAGE" \
  >/dev/null 2>&1 || fail "failed to start runner container"

sleep 5

STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
if [ "$STATE" != "running" ]; then
  warn "github-runner state: ${STATE}"
  docker logs --tail 30 "$CONTAINER_NAME" >&2 || true
  fail "github-runner container not running"
fi

ok "github-runner is up and running"

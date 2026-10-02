#!/bin/bash
# bash-scripts/upsert-github-runner.sh
# Idempotent deploy/update of a Dockerized GitHub self-hosted runner.
# The workflow preloads the image on the IPv4 runner, then loads it into
# this IPv6-only GCP VM through IAP SSH before executing this script.

set -euo pipefail

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

# --- DNS64/NAT64 Configuration ---
# Public DNS64 resolver (Google). NAT64 prefix 64:ff9b::/96 is assumed.
DNS64_SERVER="2001:4860:4860::6464"
# ------------------------------------

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

step "verifying DNS64/NAT64 connectivity"
# Test if the container can resolve an IPv4-only host to an IPv6 address
if ! docker run --rm --dns "$DNS64_SERVER" alpine:latest getent ahosts github.com | grep -q '64:ff9b::'; then
    fail "DNS64/NAT64 setup failed. Cannot resolve github.com to a NAT64 address."
fi
ok "DNS64/NAT64 connectivity verified"

step "removing existing runner container"
docker stop --time 30 "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
ok "cleanup done"

step "checking docker daemon"
docker info >/dev/null 2>&1 || fail "docker daemon is not available"
ok "docker ready"

step "checking runner image exists locally"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "${IMAGE} is not loaded on VM"
ok "image present"

step "starting runner container"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always \
  --network=host \
  --dns "$DNS64_SERVER" \
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

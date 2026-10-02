#!/bin/bash
# bash-scripts/upsert-github-runner.sh
# Forcefully removes and recreates the GitHub self-hosted runner container.
# Uses public NAT64/DNS64 for IPv6-only VMs and sudo for COS.

set -euo pipefail

CONTAINER_NAME="${GH_RUNNER_CONTAINER_NAME:-github-runner}"
IMAGE="ghcr.io/youssefbrr/self-hosted-runner:latest"
RUNNER_CPU="0.50"
RUNNER_MEMORY="256m"

REPO="${GH_RUNNER_REPO:-}"
REG_TOKEN="${GH_RUNNER_REG_TOKEN:-}"
NAME="${GH_RUNNER_NAME:-${TS_HOSTNAME:-gcp-free-tier-vm}}"
LABELS="${GH_RUNNER_LABELS:-self-hosted,linux,x64,gcp-free-tier}"
WORK_DIR="${GH_RUNNER_WORK_DIR:-_work}"
EPHEMERAL="${GH_RUNNER_EPHEMERAL:-false}"
DISABLE_AUTO_UPDATE="${GH_RUNNER_DISABLE_AUTO_UPDATE:-true}"

# Public NAT64/DNS64 gateway (nat64.net)
DNS64_1="2a00:1098:2b::1"
DNS64_2="2a00:1098:2c::1"

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

# --- Sanity: REPO must be a full URL ---
case "$REPO" in
  https://github.com/*/*) ok "REPO format looks OK" ;;
  *) fail "GH_RUNNER_REPO must be a full URL, e.g. https://github.com/OWNER/REPO" ;;
esac

# --- Sanity: token length ---
if [ ${#REG_TOKEN} -lt 20 ]; then
  fail "GH_RUNNER_REG_TOKEN looks too short — are you sure this is a registration token?"
fi
ok "token length: ${#REG_TOKEN} chars"

step "testing connectivity to GitHub API"
if ! curl -6 -s -f -m 10 https://api.github.com > /dev/null; then
    fail "Cannot reach api.github.com. NAT64/DNS64 is broken."
fi
ok "GitHub API reachable"

# --- Explicit Container Teardown ---
step "checking if runner container already exists"
if sudo docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    warn "Container '${CONTAINER_NAME}' already exists. Forcefully removing it..."
    sudo docker stop --time 10 "$CONTAINER_NAME" >/dev/null 2>&1 || true
    sudo docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    ok "existing container removed"
else
    ok "no existing container found"
fi
# -----------------------------------

step "checking docker daemon"
sudo docker info >/dev/null 2>&1 || fail "docker daemon is not available"
ok "docker ready"

step "checking runner image exists locally"
sudo docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "${IMAGE} is not loaded on VM"
ok "image present"

step "starting fresh runner container with NAT64 DNS"
sudo docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always \
  --network=host \
  --dns "$DNS64_1" \
  --dns "$DNS64_2" \
  --cpus "$RUNNER_CPU" \
  --memory "$RUNNER_MEMORY" \
  --memory-swap "$RUNNER_MEMORY" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e REPO="$REPO" \
  -e REG_TOKEN="$REG_TOKEN" \
  -e NAME="$NAME" \
  -e LABELS="$LABELS" \
  -e WORK_DIR="$WORK_DIR" \
  -e EPHEMERAL="$EPHEMERAL" \
  -e DISABLE_AUTO_UPDATE="$DISABLE_AUTO_UPDATE" \
  --log-driver json-file \
  --log-opt max-size=5m \
  --log-opt max-file=2 \
  "$IMAGE" \
  >/dev/null 2>&1 || fail "failed to start runner container"

sleep 5

STATE=$(sudo docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
if [ "$STATE" != "running" ]; then
  warn "github-runner state: ${STATE}"
  sudo docker logs --tail 30 "$CONTAINER_NAME" >&2 || true
  fail "github-runner container not running"
fi

ok "github-runner is up and running"

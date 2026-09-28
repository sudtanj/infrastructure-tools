#!/bin/bash
# bash-scripts/init-paseo-codex.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Deploys paseo-codex on host network so it inherits the host's tailscale0 routes.

set -euo pipefail

# All secrets arrive via env vars injected by the workflow
CODEX_BASE_URL="${CODEX_BASE_URL:-}"
CODEX_API_KEY="${CODEX_API_KEY:-}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_MAX_TOKEN="${CODEX_MAX_TOKEN:-8192}"
GH_TOKEN="${GH_TOKEN:-}"

IMAGE="sudtanj/paseo-codex:latest"

echo "[*] init start"

# --- Verify required secrets are present ---
echo "[>] checking required env"
missing=()
[ -z "$CODEX_API_KEY" ] && missing+=("CODEX_API_KEY")
[ -z "$GH_TOKEN" ]      && missing+=("GH_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[x] missing required env: ${missing[*]}" >&2
  exit 1
fi
echo "[+] env ok"

# --- Remove existing container ---
echo "[>] removing existing container"
docker rm -f paseo-codex >/dev/null 2>&1 || true
echo "[+] cleanup done"

# --- Ensure named volumes exist ---
docker volume create paseo-home      >/dev/null
docker volume create paseo-workspace >/dev/null

# --- Start container ---
echo "[>] starting paseo-codex"
docker run -d --name paseo-codex --restart always \
  --user 0:0 \
  --network=host \
  --cpus 0.50 \
  --memory 512m \
  --memory-swap 512m \
  --dns 2a00:1098:2b::1 \
  --dns 2a01:4f9:c010:3f02::1 \
  -v paseo-home:/home/paseo \
  -v paseo-workspace:/workspace \
  -e CODEX_BASE_URL="$CODEX_BASE_URL" \
  -e CODEX_API_KEY="$CODEX_API_KEY" \
  -e CODEX_MODEL="$CODEX_MODEL" \
  -e CODEX_MAX_TOKEN="$CODEX_MAX_TOKEN" \
  -e TERM=xterm-256color \
  -e GH_TOKEN="$GH_TOKEN" \
  "$IMAGE" \
  >/dev/null 2>&1

sleep 3

# --- Verify ---
echo "[>] verifying container"
STATE=$(docker inspect -f '{{.State.Status}}' paseo-codex 2>/dev/null || echo "missing")
if [ "$STATE" != "running" ]; then
  echo "[x] container not running (state=${STATE})" >&2
  docker logs --tail 30 paseo-codex >&2 || true
  exit 1
fi
echo "[+] container running"

NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' paseo-codex)
if [ "$NETMODE" != "host" ]; then
  echo "[x] network mode '${NETMODE}', expected 'host'" >&2
  exit 1
fi
echo "[+] network mode: host"

if ip link show tailscale0 >/dev/null 2>&1; then
  echo "[+] tailscale0 visible"
else
  echo "[!] tailscale0 not present on host — tailnet access will not work" >&2
fi

echo "[+] init done"
exit 0
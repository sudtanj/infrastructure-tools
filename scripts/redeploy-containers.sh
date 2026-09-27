#!/bin/bash
# scripts/redeploy-containers.sh
# Runs ON the VM via IAP SSH. Recreates Tailscale + Portainer without rebuilding the VM.
#
# Secrets are expected via environment variables (never hardcoded):
#   TS_AUTHKEY — Tailscale auth key (optional if state dir already authenticated)
#   TS_HOSTNAME — Tailscale node name (defaults to gcp-free-tier-vm)
#
# For host-network stacks to reach tailnet peers, use the SOCKS5 proxy:
#   ALL_PROXY=socks5h://127.0.0.1:1055
#   NO_PROXY=localhost,127.0.0.1,100.64.0.0/10,.ts.net

set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
TS_SOCKS5_PORT="${TS_SOCKS5_PORT:-1055}"
PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"

echo "[*] Redeploying containers on $(hostname) at $(date -u +%FT%TZ)"

# --- Ensure /dev/net/tun exists (COS may recreate it on reboot) ---
if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 || true
  chmod 666 /dev/net/tun || true
fi

# --- Remove existing containers (idempotent) ---
docker rm -f portainer tailscale 2>/dev/null || true

# --- Tailscale ---
# Reuse existing auth state if present; only send the auth key when needed.
if [ -f /var/lib/tailscale/tailscaled.state ] && [ -z "$TS_AUTHKEY" ]; then
  echo "[*] Existing Tailscale state found, starting without re-auth"
  TS_AUTH_ENV=""
else
  if [ -z "$TS_AUTHKEY" ]; then
    echo "[!] No TS_AUTHKEY and no existing state — Tailscale will not authenticate"
  fi
  TS_AUTH_ENV="-e TS_AUTHKEY=${TS_AUTHKEY}"
fi

# shellcheck disable=SC2086
docker run -d --name tailscale --restart always \
  --network host \
  --cpus 0.04 --cpu-shares 96 \
  --memory 96m --memory-swap 96m \
  -e GOGC=10 \
  -e GOMEMLIMIT=80MiB \
  $TS_AUTH_ENV \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=true \
  -e TS_HOSTNAME="${TS_HOSTNAME}" \
  -e "TS_EXTRA_ARGS=--advertise-tags=tag:home" \
  -e TS_AUTH_ONCE=true \
  -e TS_ACCEPT_DNS=true \
  -e TS_SOCKS5_SERVER=":${TS_SOCKS5_PORT}" \
  -e TS_OUTBOUND_HTTP_PROXY_LISTEN=":${TS_SOCKS5_PORT}" \
  -e TZ=Asia/Jakarta \
  -v /var/lib/tailscale:/var/lib/tailscale \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  tailscale/tailscale:latest

# --- Portainer ---
docker run -d --name portainer --restart always \
  --network host \
  --cpus 0.11 --cpu-shares 288 \
  --memory 192m --memory-swap 192m \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  portainer/portainer-ce:latest \
  --snapshot-interval="${PORTAINER_SNAPSHOT_INTERVAL}"

# --- Prune old images ---
docker image prune -f >/dev/null 2>&1 || true

# --- Wait for the SOCKS5 proxy to come up (Tailscale takes a few seconds) ---
echo "[*] Waiting for Tailscale SOCKS5 proxy on :${TS_SOCKS5_PORT}..."
PROXY_UP=0
for i in $(seq 1 30); do
  if (echo > /dev/tcp/127.0.0.1/"${TS_SOCKS5_PORT}") 2>/dev/null; then
    PROXY_UP=1
    break
  fi
  sleep 1
done

if [ "$PROXY_UP" -eq 1 ]; then
  echo "[+] SOCKS5 proxy is listening on 127.0.0.1:${TS_SOCKS5_PORT}"
else
  echo "[!] SOCKS5 proxy did not come up within 30s — check 'docker logs tailscale'"
fi

# --- Report ---
echo "[*] Running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"

echo "[*] Tailscale status:"
docker exec tailscale tailscale status 2>/dev/null || echo "  (tailscale still starting)"

echo "[*] Done."

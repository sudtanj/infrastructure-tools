#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Reuses existing Tailscale state in /var/lib/tailscale.
#
# Starts:
#   - tailscale   (userspace mode, SOCKS5 proxy on :1055)
#   - ts-proxy    (transparent proxy sidecar — xavierlam/proxy-sidecar)
#   - portainer   (management UI on bridge network)
#
# App stacks get transparent tailnet access with:
#   network_mode: "service:ts-proxy"
#
# Fully silent by default. VERBOSE=1 for diagnostic output (stderr only).

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
TS_SOCKS5_PORT="${TS_SOCKS5_PORT:-1055}"
TS_NETWORK="${TS_NETWORK:-tailscale-net}"
PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"

log() { if [ "$VERBOSE" = "1" ]; then printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" >&2; fi; }

log "Init started"

# --- /dev/net/tun ---
if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 >/dev/null 2>&1 || true
  chmod 666 /dev/net/tun >/dev/null 2>&1 || true
fi

# --- Docker network ---
docker network create "$TS_NETWORK" >/dev/null 2>&1 || true
log "Network ready: $TS_NETWORK"

# --- Remove existing containers ---
docker rm -f portainer ts-proxy tailscale >/dev/null 2>&1 || true
log "Old containers removed"

# --- Detect existing Tailscale state ---
TS_STATE_PRESENT=0
if [ -s /var/lib/tailscale/tailscaled.state ] \
   || [ -d /var/lib/tailscale/tailscaled.state.d ] \
   || ls /var/lib/tailscale/*.state >/dev/null 2>&1; then
  TS_STATE_PRESENT=1
fi

if [ "$TS_STATE_PRESENT" -eq 1 ] && [ -z "$TS_AUTHKEY" ]; then
  log "Reusing existing Tailscale state"
  TS_AUTH_ENV=""
elif [ -n "$TS_AUTHKEY" ]; then
  log "Authenticating Tailscale with provided key"
  TS_AUTH_ENV="-e TS_AUTHKEY=${TS_AUTHKEY}"
else
  log "No state and no auth key"
  TS_AUTH_ENV=""
fi

# --- Tailscale (userspace, SOCKS5 proxy bound to 0.0.0.0) ---
# shellcheck disable=SC2086
docker run -d --name tailscale --restart always \
  --network "$TS_NETWORK" \
  --cpus 0.04 --cpu-shares 96 \
  --memory 96m --memory-swap 96m \
  -e GOGC=10 -e GOMEMLIMIT=80MiB \
  $TS_AUTH_ENV \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=true \
  -e TS_HOSTNAME="${TS_HOSTNAME}" \
  -e "TS_EXTRA_ARGS=--advertise-tags=tag:home" \
  -e TS_AUTH_ONCE=true -e TS_ACCEPT_DNS=true \
  -e TS_SOCKS5_SERVER="0.0.0.0:${TS_SOCKS5_PORT}" \
  -e TS_OUTBOUND_HTTP_PROXY_LISTEN="0.0.0.0:${TS_SOCKS5_PORT}" \
  -e TZ=Asia/Jakarta \
  -v /var/lib/tailscale:/var/lib/tailscale \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  tailscale/tailscale:latest \
  >/dev/null 2>&1

# --- Wait for Tailscale to be ready ---
TS_READY=0
for _ in $(seq 1 60); do
  if docker exec tailscale tailscale ip -4 >/dev/null 2>&1; then
    TS_READY=1
    break
  fi
  sleep 2
done
log "Tailscale ready: ${TS_READY}"

# --- Transparent proxy sidecar ---
# xavierlam/proxy-sidecar intercepts outbound TCP via iptables and
# forwards through the upstream SOCKS5 proxy (Tailscale's :1055).
# It must share its network namespace with the app containers that
# want transparent access — they use network_mode: "service:ts-proxy".
docker run -d --name ts-proxy --restart always \
  --network "$TS_NETWORK" \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --cpus 0.03 --cpu-shares 64 \
  --memory 64m --memory-swap 64m \
  -e PROXY_SERVER=tailscale \
  -e PROXY_PORT="${TS_SOCKS5_PORT}" \
  -e PROXY_TYPE=socks5 \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  xavierlam/proxy-sidecar:latest \
  >/dev/null 2>&1
log "ts-proxy started"

# --- Portainer (own bridge network, published ports) ---
docker run -d --name portainer --restart always \
  --network bridge \
  -p 9000:9000 -p 9443:9443 \
  --cpus 0.11 --cpu-shares 288 \
  --memory 192m --memory-swap 192m \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  portainer/portainer-ce:latest \
  --snapshot-interval="${PORTAINER_SNAPSHOT_INTERVAL}" \
  >/dev/null 2>&1
log "Portainer started"

docker image prune -f >/dev/null 2>&1 || true

# --- Verify SOCKS5 proxy is reachable ---
PROXY_UP=0
for _ in $(seq 1 30); do
  if docker exec tailscale sh -c "echo > /dev/tcp/127.0.0.1/${TS_SOCKS5_PORT}" 2>/dev/null; then
    PROXY_UP=1
    break
  fi
  sleep 1
done
log "SOCKS5 ready: ${PROXY_UP}"

if [ "$TS_READY" -ne 1 ] || [ "$PROXY_UP" -ne 1 ]; then
  exit 1
fi

log "Init done"
exit 0
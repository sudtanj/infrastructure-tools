#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Reuses existing Tailscale state in /var/lib/tailscale.
#
# Builds a custom transparent proxy sidecar locally (no external image),
# then starts: tailscale, ts-sidecar, portainer.
#
# App stacks get transparent tailnet access with:
#   network_mode: "service:ts-sidecar"
#
# Emits minimal status lines. No IPs, peer names, container names, or paths.

set -euo pipefail

VERBOSE="${VERBOSE:-0}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
TS_SOCKS5_PORT="${TS_SOCKS5_PORT:-1055}"
TS_NETWORK="${TS_NETWORK:-tailscale-net}"
SIDECAR_IMAGE="${SIDECAR_IMAGE:-ts-sidecar:local}"
PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"
BUILD_DIR="/var/lib/ts-sidecar-build"

status() { printf '[*] %s\n' "$*"; }
debug() { if [ "$VERBOSE" = "1" ]; then printf '[dbg] %s\n' "$*" >&2; fi; }

status "init start"

# --- /dev/net/tun ---
if [ ! -e /dev/net/tun ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200 >/dev/null 2>&1 || true
  chmod 666 /dev/net/tun >/dev/null 2>&1 || true
  debug "created /dev/net/tun"
fi

# --- Docker network ---
docker network create "$TS_NETWORK" >/dev/null 2>&1 || true
status "network ready"

# --- Remove existing containers ---
docker rm -f portainer ts-sidecar tailscale >/dev/null 2>&1 || true
status "old containers removed"

# --- Build the sidecar image locally ---
status "building sidecar image"
mkdir -p "$BUILD_DIR"

cat > "${BUILD_DIR}/Dockerfile" <<'DOCKERFILE'
FROM alpine:3.20

RUN apk add --no-cache gost iptables iproute2

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE

cat > "${BUILD_DIR}/entrypoint.sh" <<'ENTRYPOINT'
#!/bin/sh
set -e

PROXY_SERVER="${PROXY_SERVER:-tailscale}"
PROXY_PORT="${PROXY_PORT:-1055}"

echo "starting gost proxy"
gost -L "redirect://:12345" -F "socks5://${PROXY_SERVER}:${PROXY_PORT}" &

# Wait for gost to be listening
for i in $(seq 1 30); do
  if (echo > /dev/tcp/127.0.0.1/12345) 2>/dev/null; then
    break
  fi
  sleep 1
done

echo "configuring iptables"

iptables -t nat -N REDSOCKS 2>/dev/null || true
iptables -t nat -F REDSOCKS

for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
            169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
            224.0.0.0/4 240.0.0.0/4; do
  iptables -t nat -A REDSOCKS -d "$cidr" -j RETURN
done

iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports 12345
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

echo "sidecar ready"
exec tail -f /dev/null
ENTRYPOINT

docker build -t "$SIDECAR_IMAGE" "$BUILD_DIR" >/dev/null 2>&1
status "sidecar image built"

# --- Detect existing Tailscale state ---
TS_STATE_PRESENT=0
if [ -s /var/lib/tailscale/tailscaled.state ] \
   || [ -d /var/lib/tailscale/tailscaled.state.d ] \
   || ls /var/lib/tailscale/*.state >/dev/null 2>&1; then
  TS_STATE_PRESENT=1
fi

if [ "$TS_STATE_PRESENT" -eq 1 ] && [ -z "$TS_AUTHKEY" ]; then
  status "tailscale: reusing existing state"
  TS_AUTH_ENV=""
elif [ -n "$TS_AUTHKEY" ]; then
  status "tailscale: authenticating with provided key"
  TS_AUTH_ENV="-e TS_AUTHKEY=${TS_AUTHKEY}"
else
  status "tailscale: no state and no auth key (may stay offline)"
  TS_AUTH_ENV=""
fi

# --- Start Tailscale on the dedicated network ---
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

if [ "$TS_READY" -eq 1 ]; then
  status "tailscale: connected"
else
  status "tailscale: NOT connected"
fi

# --- Start the sidecar (shares network with apps via network_mode: service:ts-sidecar) ---
docker run -d --name ts-sidecar --restart always \
  --network "$TS_NETWORK" \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --cpus 0.05 --cpu-shares 128 \
  --memory 128m --memory-swap 128m \
  -e PROXY_SERVER=tailscale \
  -e PROXY_PORT="${TS_SOCKS5_PORT}" \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  "$SIDECAR_IMAGE" \
  >/dev/null 2>&1

# --- Verify sidecar came up (not in a restart loop) ---
sleep 5
SIDECAR_STATE=$(docker inspect -f '{{.State.Status}}' ts-sidecar 2>/dev/null || echo "missing")
if [ "$SIDECAR_STATE" = "running" ]; then
  status "sidecar: running"
else
  status "sidecar: NOT running (state=${SIDECAR_STATE})"
fi

# --- Start Portainer ---
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
status "portainer: started"

docker image prune -f >/dev/null 2>&1 || true

# --- Verify SOCKS5 proxy is reachable from inside the Tailscale container ---
PROXY_UP=0
for _ in $(seq 1 30); do
  if docker exec tailscale sh -c "echo > /dev/tcp/127.0.0.1/${TS_SOCKS5_PORT}" 2>/dev/null; then
    PROXY_UP=1
    break
  fi
  sleep 1
done

if [ "$PROXY_UP" -eq 1 ]; then
  status "socks5: listening"
else
  status "socks5: NOT reachable"
fi

# --- Final summary ---
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
status "running containers: ${RUNNING}"
status "init done"

if [ "$TS_READY" -ne 1 ] || [ "$PROXY_UP" -ne 1 ]; then
  exit 1
fi
exit 0
#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Runs ON the VM via IAP SSH. Idempotent.

set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
TS_SOCKS5_PORT="${TS_SOCKS5_PORT:-1055}"
TS_NETWORK="${TS_NETWORK:-tailscale-net}"
SIDECAR_IMAGE="${SIDECAR_IMAGE:-ts-sidecar:local}"
PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"
BUILD_DIR="/tmp/ts-sidecar-build"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

redact() {
  grep -vE \
    '([0-9]{1,3}\.){3}[0-9]{1,3}|@[A-Za-z0-9.-]+\.|ts\.net|\.googleapis\.com|projects/[0-9]+|zones/[a-z0-9-]+|instances/[A-Za-z0-9-]+|BEGIN [A-Z ]+KEY|PRIVATE KEY|Bearer [A-Za-z0-9._-]+|tskey-[A-Za-z0-9-]+' \
    || true
}

container_state() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "missing"; }
container_netmode() { docker inspect -f '{{.HostConfig.NetworkMode}}' "$1" 2>/dev/null || echo "missing"; }

status "init start"

# --- Pre-flight: credentials ---
step "checking credentials"
TS_STATE_PRESENT=0
if [ -s /var/lib/tailscale/tailscaled.state ] \
   || [ -d /var/lib/tailscale/tailscaled.state.d ] \
   || ls /var/lib/tailscale/*.state >/dev/null 2>&1; then
  TS_STATE_PRESENT=1
fi

TS_AUTH_ENV=""
if [ -n "$TS_AUTHKEY" ]; then
  ok "auth key provided"
  TS_AUTH_ENV="-e TS_AUTHKEY=${TS_AUTHKEY}"
elif [ "$TS_STATE_PRESENT" -eq 1 ]; then
  ok "existing state found"
else
  fail "no auth key and no existing state"
fi

# --- Verify host has IPv6 connectivity (required for Tailscale control plane) ---
step "checking host IPv6 connectivity"
if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
  ok "host has global IPv6 address"
else
  fail "host has no global IPv6 address — Tailscale cannot reach its control plane"
fi

if ip -6 route show default 2>/dev/null | grep -q "default"; then
  ok "host has IPv6 default route"
else
  fail "host has no IPv6 default route"
fi

# --- /dev/net/tun ---
if [ ! -e /dev/net/tun ]; then
  sudo mkdir -p /dev/net 2>/dev/null || true
  sudo mknod /dev/net/tun c 10 200 >/dev/null 2>&1 || true
  sudo chmod 666 /dev/net/tun >/dev/null 2>&1 || true
fi

# --- Docker network for the sidecar ---
docker network inspect "$TS_NETWORK" >/dev/null 2>&1 || docker network create "$TS_NETWORK" >/dev/null 2>&1 || fail "network create failed"
ok "network ready"

# --- Cleanup ---
step "removing existing containers"
docker rm -f portainer ts-sidecar tailscale >/dev/null 2>&1 || true
ok "cleanup done"

# --- Build sidecar ---
step "building sidecar image"
mkdir -p "$BUILD_DIR" || fail "build dir not writable"

cat > "${BUILD_DIR}/Dockerfile" <<'DOCKERFILE'
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       redsocks iptables iproute2 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
DOCKERFILE

cat > "${BUILD_DIR}/entrypoint.sh" <<'ENTRYPOINT'
#!/bin/sh
set -e

PROXY_SERVER="${PROXY_SERVER:-tailscale}"
PROXY_PORT="${PROXY_PORT:-1055}"
LOCAL_PORT="${LOCAL_PORT:-12345}"

cat > /etc/redsocks.conf <<EOF
base {
    log_debug = off;
    log_info = off;
    log = "stderr";
    daemon = off;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = ${LOCAL_PORT};
    ip = ${PROXY_SERVER};
    port = ${PROXY_PORT};
    type = socks5;
}
EOF

/usr/sbin/redsocks -c /etc/redsocks.conf &

for i in $(seq 1 30); do
  if (echo > /dev/tcp/127.0.0.1/${LOCAL_PORT}) 2>/dev/null; then
    break
  fi
  sleep 1
done

iptables -t nat -N REDSOCKS 2>/dev/null || true
iptables -t nat -F REDSOCKS

for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
            169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
            224.0.0.0/4 240.0.0.0/4; do
  iptables -t nat -A REDSOCKS -d "$cidr" -j RETURN
done

iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports ${LOCAL_PORT}
iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

exec tail -f /dev/null
ENTRYPOINT

BUILD_LOG=$(mktemp)
if docker build --network host -t "$SIDECAR_IMAGE" "$BUILD_DIR" > "$BUILD_LOG" 2>&1; then
  ok "sidecar image built"
  rm -f "$BUILD_LOG"
else
  warn "sidecar build failed"
  printf '%s\n' "---- build tail (redacted) ----" >&2
  tail -40 "$BUILD_LOG" | redact >&2
  printf '%s\n' "---- end ----" >&2
  rm -f "$BUILD_LOG"
  exit 1
fi

# --- Start Tailscale with EXPLICIT host network ---
step "starting tailscale on host network"

# shellcheck disable=SC2086
docker run -d --name tailscale --restart always \
  --network=host \
  --cpus 0.04 --cpu-shares 96 \
  --memory 96m --memory-swap 96m \
  -e GOGC=10 -e GOMEMLIMIT=80MiB \
  $TS_AUTH_ENV \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=true \
  -e TS_HOSTNAME="${TS_HOSTNAME}" \
  -e "TS_EXTRA_ARGS=--advertise-tags=tag:home" \
  -e TS_AUTH_ONCE=true \
  -e TS_ACCEPT_DNS=true \
  -e TS_SOCKS5_SERVER="0.0.0.0:${TS_SOCKS5_PORT}" \
  -e TS_OUTBOUND_HTTP_PROXY_LISTEN="0.0.0.0:${TS_SOCKS5_PORT}" \
  -e TZ=Asia/Jakarta \
  -v /var/lib/tailscale:/var/lib/tailscale \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  tailscale/tailscale:latest \
  >/dev/null 2>&1 || fail "docker run failed"

# --- VERIFY the network mode is actually host ---
sleep 2
NETMODE=$(container_netmode tailscale)
if [ "$NETMODE" != "host" ]; then
  warn "container network mode is '${NETMODE}', expected 'host'"
  fail "tailscale is not on host network — cannot reach IPv6 internet"
fi
ok "tailscale network mode verified: host"

# --- Verify container has IPv6 inside ---
if docker exec tailscale sh -c 'ip -6 addr show scope global 2>/dev/null | grep -q inet6' 2>/dev/null; then
  ok "tailscale container has IPv6"
else
  warn "tailscale container has no IPv6 — control plane will be unreachable"
  fail "container lacks IPv6"
fi

# --- Wait for connection (short timeout, fail fast) ---
step "waiting for tailscale to connect"
TS_READY=0
for i in $(seq 1 30); do
  STATE=$(container_state tailscale)
  if [ "$STATE" != "running" ]; then
    warn "tailscale container died (state=${STATE})"
    break
  fi
  if docker exec tailscale tailscale ip -4 >/dev/null 2>&1; then
    TS_READY=1
    break
  fi
  sleep 2
done

if [ "$TS_READY" -ne 1 ]; then
  warn "tailscale did not connect in 60s"
  printf '%s\n' "---- tailscale last 20 lines (redacted) ----" >&2
  docker logs --tail 20 tailscale 2>&1 | redact >&2 || true
  printf '%s\n' "---- end ----" >&2
  fail "tailscale connection failed"
fi
ok "tailscale connected"

# --- Start sidecar ---
step "starting sidecar"
docker run -d --name ts-sidecar --restart always \
  --network "$TS_NETWORK" \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --add-host=tailscale:host-gateway \
  --cpus 0.05 --cpu-shares 128 \
  --memory 128m --memory-swap 128m \
  -e PROXY_SERVER=tailscale \
  -e PROXY_PORT="${TS_SOCKS5_PORT}" \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  "$SIDECAR_IMAGE" \
  >/dev/null 2>&1 || fail "sidecar failed to start"

sleep 5
if [ "$(container_state ts-sidecar)" = "running" ]; then
  ok "sidecar running"
else
  warn "sidecar not running"
  docker logs --tail 20 ts-sidecar 2>&1 | redact >&2 || true
  fail "sidecar not stable"
fi

# --- Start Portainer ---
step "starting portainer"
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
  >/dev/null 2>&1 || fail "portainer failed to start"
ok "portainer running"

docker image prune -f >/dev/null 2>&1 || true

# --- Verify SOCKS5 ---
step "verifying socks5"
PROXY_UP=0
for i in $(seq 1 30); do
  if docker exec tailscale sh -c "echo > /dev/tcp/127.0.0.1/${TS_SOCKS5_PORT}" 2>/dev/null; then
    PROXY_UP=1
    break
  fi
  sleep 1
done

if [ "$PROXY_UP" -eq 1 ]; then
  ok "socks5 listening"
else
  warn "socks5 not reachable"
fi

# --- Verify sidecar can reach the proxy ---
step "verifying sidecar path"
SIDECAR_PATH=0
if docker exec ts-sidecar sh -c "echo > /dev/tcp/tailscale/${TS_SOCKS5_PORT}" 2>/dev/null; then
  SIDECAR_PATH=1
  ok "sidecar can reach proxy"
else
  warn "sidecar cannot reach proxy"
fi

# --- Summary ---
step "summary"
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
status "containers running: ${RUNNING}"
status "tailscale ready: ${TS_READY}"
status "socks5 ready: ${PROXY_UP}"
status "sidecar path ready: ${SIDECAR_PATH}"

if [ "$TS_READY" -ne 1 ] || [ "$PROXY_UP" -ne 1 ] || [ "$SIDECAR_PATH" -ne 1 ]; then
  fail "init failed"
fi

ok "init done"
exit 0
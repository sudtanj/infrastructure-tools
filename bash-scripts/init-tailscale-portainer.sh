#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Reuses existing Tailscale state in /var/lib/tailscale.
#
# Builds a redsocks-based transparent proxy sidecar locally, then starts:
#   tailscale, ts-sidecar, portainer.
#
# App stacks get transparent tailnet access with:
#   network_mode: "service:ts-sidecar"

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

# Returns the container's state (running / exited / missing), never its name.
container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "missing"
}

status "init start"

# ---------------------------------------------------------------------------
# 0. Pre-flight: verify we have something to authenticate with
# ---------------------------------------------------------------------------
step "checking tailscale credentials"

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
  fail "no auth key and no existing state — nothing to authenticate with"
fi

# ---------------------------------------------------------------------------
# 1. /dev/net/tun
# ---------------------------------------------------------------------------
step "checking /dev/net/tun"
if [ -e /dev/net/tun ]; then
  ok "tun device present"
else
  sudo mkdir -p /dev/net 2>/dev/null || true
  sudo mknod /dev/net/tun c 10 200 >/dev/null 2>&1 || true
  sudo chmod 666 /dev/net/tun >/dev/null 2>&1 || true
  if [ -e /dev/net/tun ]; then
    ok "tun device created"
  else
    warn "tun device not created (userspace mode does not require it)"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Docker network
# ---------------------------------------------------------------------------
step "ensuring docker network"
if docker network inspect "$TS_NETWORK" >/dev/null 2>&1; then
  ok "network exists"
else
  docker network create "$TS_NETWORK" >/dev/null 2>&1 || fail "network create failed"
  ok "network created"
fi

# ---------------------------------------------------------------------------
# 3. Remove old containers
# ---------------------------------------------------------------------------
step "removing existing containers"
docker rm -f portainer ts-sidecar tailscale >/dev/null 2>&1 || true
ok "cleanup done"

# ---------------------------------------------------------------------------
# 4. Build sidecar image
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 5. Start Tailscale
# ---------------------------------------------------------------------------
step "starting tailscale"

# shellcheck disable=SC2086
if ! docker run -d --name tailscale --restart always \
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
  >/dev/null 2>&1; then
  fail "tailscale container failed to start"
fi
ok "tailscale container started"

# Give the container a moment to either stabilize or crash
sleep 5
STATE=$(container_state tailscale)
if [ "$STATE" != "running" ]; then
  fail "tailscale container exited immediately (state=${STATE})"
fi
ok "tailscale container stayed up"

# ---------------------------------------------------------------------------
# 6. Wait for Tailscale to connect
# ---------------------------------------------------------------------------
step "waiting for tailscale to connect"
TS_READY=0
for i in $(seq 1 60); do
  # Re-check the container hasn't crashed while we wait
  STATE=$(container_state tailscale)
  if [ "$STATE" != "running" ]; then
    warn "tailscale container died while waiting (state=${STATE})"
    break
  fi

  if docker exec tailscale tailscale ip -4 >/dev/null 2>&1; then
    TS_READY=1
    break
  fi
  sleep 2
done

if [ "$TS_READY" -eq 1 ]; then
  ok "tailscale connected"
else
  warn "tailscale did not connect within timeout"
  fail "aborting — sidecar and portainer need a working tailscale"
fi

# ---------------------------------------------------------------------------
# 7. Start the sidecar
# ---------------------------------------------------------------------------
step "starting sidecar"

if ! docker run -d --name ts-sidecar --restart always \
  --network "$TS_NETWORK" \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --cpus 0.05 --cpu-shares 128 \
  --memory 128m --memory-swap 128m \
  -e PROXY_SERVER=tailscale \
  -e PROXY_PORT="${TS_SOCKS5_PORT}" \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  "$SIDECAR_IMAGE" \
  >/dev/null 2>&1; then
  fail "sidecar container failed to start"
fi

sleep 5
SIDECAR_STATE=$(container_state ts-sidecar)
if [ "$SIDECAR_STATE" = "running" ]; then
  ok "sidecar running"
else
  warn "sidecar not running (state=${SIDECAR_STATE})"
  printf '%s\n' "---- sidecar logs (redacted) ----" >&2
  docker logs --tail 30 ts-sidecar 2>&1 | redact >&2 || true
  printf '%s\n' "---- end ----" >&2
  fail "sidecar not stable"
fi

# ---------------------------------------------------------------------------
# 8. Start Portainer
# ---------------------------------------------------------------------------
step "starting portainer"

if ! docker run -d --name portainer --restart always \
  --network bridge \
  -p 9000:9000 -p 9443:9443 \
  --cpus 0.11 --cpu-shares 288 \
  --memory 192m --memory-swap 192m \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  portainer/portainer-ce:latest \
  --snapshot-interval="${PORTAINER_SNAPSHOT_INTERVAL}" \
  >/dev/null 2>&1; then
  fail "portainer container failed to start"
fi
ok "portainer running"

# ---------------------------------------------------------------------------
# 9. Prune unused images
# ---------------------------------------------------------------------------
step "pruning unused images"
docker image prune -f >/dev/null 2>&1 || true
ok "prune done"

# ---------------------------------------------------------------------------
# 10. Verify SOCKS5 proxy is reachable
# ---------------------------------------------------------------------------
step "verifying socks5 proxy"
PROXY_UP=0
for i in $(seq 1 30); do
  STATE=$(container_state tailscale)
  if [ "$STATE" != "running" ]; then
    warn "tailscale container died before proxy check"
    break
  fi

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

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
step "summary"

RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
status "containers running: ${RUNNING}"
status "tailscale ready: ${TS_READY}"
status "socks5 ready: ${PROXY_UP}"

if [ "$PROXY_UP" -ne 1 ]; then
  fail "init failed"
fi

ok "init done"
exit 0
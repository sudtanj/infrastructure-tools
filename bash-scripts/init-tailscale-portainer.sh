#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Fixes: masks containers.service so it can't respawn, removes the bridge
# network, forces host networking, hard-verifies with three separate checks.

set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
TS_SOCKS5_PORT="${TS_SOCKS5_PORT:-1055}"
PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

status "init start"

# ---------------------------------------------------------------------------
# 0. Mask containers.service permanently
# ---------------------------------------------------------------------------
step "masking competing systemd units"
if systemctl list-unit-files 2>/dev/null | grep -q '^containers\.service'; then
  sudo systemctl stop containers.service    2>/dev/null || true
  sudo systemctl disable containers.service 2>/dev/null || true
  sudo systemctl mask containers.service    2>/dev/null || true
  sudo rm -f /etc/systemd/system/containers.service
  sudo systemctl daemon-reload              2>/dev/null || true
  ok "containers.service masked"
else
  ok "no competing unit"
fi

# ---------------------------------------------------------------------------
# 1. Credentials
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 2. Cleanup — remove containers AND the bridge network
# ---------------------------------------------------------------------------
step "removing competing containers and networks"
docker rm -f tailscale portainer ts-sidecar ts-proxy >/dev/null 2>&1 || true
docker network rm tailscale-net >/dev/null 2>&1 || true
ok "cleanup done"

# ---------------------------------------------------------------------------
# 3. Start Tailscale on host network
# ---------------------------------------------------------------------------
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

sleep 3

# ---------------------------------------------------------------------------
# 4. Hard verification
# ---------------------------------------------------------------------------
step "verifying host network"
NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' tailscale 2>/dev/null || echo "missing")
if [ "$NETMODE" != "host" ]; then
  fail "network mode is '${NETMODE}', expected 'host' — something recreated the container"
fi
ok "network mode: host"

if ! docker exec tailscale sh -c 'ip -6 addr show scope global 2>/dev/null | grep -q inet6'; then
  warn "container has no IPv6"
  docker exec tailscale ip -6 addr show 2>&1 | head -20 >&2 || true
  fail "container lacks IPv6"
fi
ok "IPv6 visible inside container"

# ---------------------------------------------------------------------------
# 5. Wait for Tailscale to connect
# ---------------------------------------------------------------------------
step "waiting for tailscale to connect"
TS_READY=0
for i in $(seq 1 60); do
  STATE=$(docker inspect -f '{{.State.Status}}' tailscale 2>/dev/null || echo "missing")
  [ "$STATE" = "running" ] || { warn "container died (${STATE})"; break; }
  if docker exec tailscale tailscale ip -4 >/dev/null 2>&1; then
    TS_READY=1
    break
  fi
  sleep 2
done

if [ "$TS_READY" -ne 1 ]; then
  warn "tailscale not connected in 120s"
  printf '%s\n' "---- last 30 lines of tailscale log ----" >&2
  docker logs --tail 30 tailscale >&2 || true
  printf '%s\n' "---- end ----" >&2
  fail "tailscale connection failed"
fi
ok "tailscale connected"

# ---------------------------------------------------------------------------
# 6. Start Portainer
# ---------------------------------------------------------------------------
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
  >/dev/null 2>&1 || fail "portainer failed"
ok "portainer running"

docker image prune -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. SOCKS5
# ---------------------------------------------------------------------------
step "verifying socks5"
PROXY_UP=0
for i in $(seq 1 30); do
  if docker exec tailscale sh -c "echo > /dev/tcp/127.0.0.1/${TS_SOCKS5_PORT}" 2>/dev/null; then
    PROXY_UP=1
    break
  fi
  sleep 1
done
[ "$PROXY_UP" -eq 1 ] || fail "socks5 not reachable"
ok "socks5 listening"

# ---------------------------------------------------------------------------
# 8. Final re-check — catches anything that tries to recreate late
# ---------------------------------------------------------------------------
sleep 10
FINAL=$(docker inspect -f '{{.HostConfig.NetworkMode}}' tailscale 2>/dev/null || echo "missing")
[ "$FINAL" = "host" ] || fail "recreated on '${FINAL}' — a supervisor is still running"

RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
status "running containers: ${RUNNING}"
ok "init done"
exit 0
#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Runs ON the VM via IAP SSH. Idempotent.

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

container_state() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || echo "missing"; }
container_netmode() { docker inspect -f '{{.HostConfig.NetworkMode}}' "$1" 2>/dev/null || echo "missing"; }

status "init start"

# ---------------------------------------------------------------------------
# 0. Neutralize any competing systemd unit
# ---------------------------------------------------------------------------
step "disabling competing systemd units"
if systemctl list-unit-files 2>/dev/null | grep -q '^containers.service'; then
  sudo systemctl stop containers.service 2>/dev/null || true
  sudo systemctl disable containers.service 2>/dev/null || true
  sudo rm -f /etc/systemd/system/containers.service
  sudo systemctl daemon-reload 2>/dev/null || true
  ok "containers.service removed"
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
# 2. Clean up ALL competing containers
# ---------------------------------------------------------------------------
step "cleaning up containers"
docker rm -f portainer tailscale ts-sidecar ts-proxy >/dev/null 2>&1 || true
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
  -e TS_AUTH_ONCE=true -e TS_ACCEPT_DNS=true \
  -e TS_SOCKS5_SERVER="0.0.0.0:${TS_SOCKS5_PORT}" \
  -e TS_OUTBOUND_HTTP_PROXY_LISTEN="0.0.0.0:${TS_SOCKS5_PORT}" \
  -e TZ=Asia/Jakarta \
  -v /var/lib/tailscale:/var/lib/tailscale \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  tailscale/tailscale:latest \
  >/dev/null 2>&1 || fail "docker run failed"

sleep 3

# ---------------------------------------------------------------------------
# 4. Verify it's actually on host network
# ---------------------------------------------------------------------------
step "verifying host network"

NETMODE=$(container_netmode tailscale)
if [ "$NETMODE" != "host" ]; then
  fail "container is on network '${NETMODE}', expected 'host'"
fi
ok "network mode: host"

# Verify IPv6 is visible inside the container
if ! docker exec tailscale sh -c 'ip -6 addr show scope global 2>/dev/null | grep -q inet6'; then
  warn "container has no IPv6 — check host IPv6 config"
  docker exec tailscale ip -6 addr show 2>&1 | head -20 >&2 || true
  fail "IPv6 unavailable in container"
fi
ok "IPv6 visible in container"

# ---------------------------------------------------------------------------
# 5. Wait for Tailscale to connect
# ---------------------------------------------------------------------------
step "waiting for tailscale to connect"
TS_READY=0
for i in $(seq 1 60); do
  STATE=$(container_state tailscale)
  if [ "$STATE" != "running" ]; then
    warn "container died (state=${STATE})"
    break
  fi
  if docker exec tailscale tailscale ip -4 >/dev/null 2>&1; then
    TS_READY=1
    break
  fi
  sleep 2
done

if [ "$TS_READY" -ne 1 ]; then
  warn "tailscale did not connect in 120s"
  printf '%s\n' "---- tailscale logs (last 30 lines) ----" >&2
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
  >/dev/null 2>&1 || fail "portainer failed to start"
ok "portainer running"

docker image prune -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. Verify SOCKS5
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

if [ "$PROXY_UP" -eq 1 ]; then
  ok "socks5 listening"
else
  fail "socks5 not reachable"
fi

# ---------------------------------------------------------------------------
# 8. Final check: re-verify network mode (catch anything that tried to recreate)
# ---------------------------------------------------------------------------
sleep 10
FINAL_MODE=$(container_netmode tailscale)
if [ "$FINAL_MODE" != "host" ]; then
  fail "tailscale was re-created on network '${FINAL_MODE}' — something is respawning it"
fi

RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
status "running containers: ${RUNNING}"
ok "init done"
exit 0
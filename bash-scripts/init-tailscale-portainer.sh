#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Tailscale kernel-mode container on host network + Portainer.
# No userspace mode, no SOCKS5 proxy, no sidecar, no static binary.

set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

status "init start"

# ---------------------------------------------------------------------------
# 0. Remove anything from earlier attempts
# ---------------------------------------------------------------------------
step "cleaning up old state"
docker rm -f tailscale ts-sidecar ts-proxy portainer 2>/dev/null || true
docker network rm tailscale-net 2>/dev/null || true
sudo systemctl mask containers.service 2>/dev/null || true
sudo systemctl stop containers.service 2>/dev/null || true
sudo systemctl disable containers.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/containers.service /etc/systemd/system/tailscaled.service
sudo systemctl daemon-reload 2>/dev/null || true
ok "cleanup done"

# ---------------------------------------------------------------------------
# 1. Ensure /dev/net/tun exists
# ---------------------------------------------------------------------------
step "ensuring /dev/net/tun"
if [ ! -e /dev/net/tun ]; then
  sudo mkdir -p /dev/net
  sudo mknod /dev/net/tun c 10 200 2>/dev/null || true
  sudo chmod 666 /dev/net/tun
fi
if [ ! -e /dev/net/tun ]; then
  fail "cannot create /dev/net/tun"
fi
ok "tun device ready"

# ---------------------------------------------------------------------------
# 2. Ensure state directory
# ---------------------------------------------------------------------------
sudo mkdir -p /var/lib/tailscale
sudo chmod 700 /var/lib/tailscale

# ---------------------------------------------------------------------------
# 3. Start Tailscale in KERNEL mode on HOST network
# ---------------------------------------------------------------------------
step "starting tailscale (kernel mode, host network)"

if [ -n "$TS_AUTHKEY" ]; then
  TS_AUTH_ENV="-e TS_AUTHKEY=${TS_AUTHKEY}"
else
  TS_AUTH_ENV=""
fi

# shellcheck disable=SC2086
docker run -d --name tailscale --restart always \
  --network=host \
  --cap-add=NET_ADMIN \
  --cap-add=NET_RAW \
  --device=/dev/net/tun \
  --cpus 0.04 --cpu-shares 96 \
  --memory 96m --memory-swap 96m \
  -e GOGC=10 -e GOMEMLIMIT=80MiB \
  $TS_AUTH_ENV \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=false \
  -e TS_HOSTNAME="${TS_HOSTNAME}" \
  -e TS_EXTRA_ARGS="--advertise-tags=tag:home" \
  -e TS_AUTH_ONCE=true \
  -e TS_ACCEPT_DNS=true \
  -e TZ=Asia/Jakarta \
  -v /var/lib/tailscale:/var/lib/tailscale \
  -v /dev/net/tun:/dev/net/tun \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  tailscale/tailscale:latest \
  >/dev/null 2>&1 || fail "tailscale docker run failed"

sleep 5

# Container must still be running
STATE=$(docker inspect -f '{{.State.Status}}' tailscale 2>/dev/null || echo "missing")
if [ "$STATE" != "running" ]; then
  warn "container state: ${STATE}"
  docker logs --tail 30 tailscale >&2 || true
  fail "tailscale container not running"
fi
ok "tailscale container running"

# Must be on host network
NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' tailscale)
if [ "$NETMODE" != "host" ]; then
  fail "network mode '${NETMODE}', expected 'host'"
fi
ok "network mode: host"

# ---------------------------------------------------------------------------
# 4. Wait for the tailscale0 interface to appear on the HOST
# ---------------------------------------------------------------------------
step "waiting for tailscale0 interface"
TS_READY=0
for i in $(seq 1 60); do
  STATE=$(docker inspect -f '{{.State.Status}}' tailscale 2>/dev/null || echo "missing")
  if [ "$STATE" != "running" ]; then
    warn "container died (state=${STATE})"
    docker logs --tail 40 tailscale >&2 || true
    break
  fi

  if ip link show tailscale0 >/dev/null 2>&1; then
    TS_READY=1
    break
  fi
  sleep 2
done

if [ "$TS_READY" -ne 1 ]; then
  warn "tailscale0 did not appear in 120s"
  printf '%s\n' "---- tailscale logs ----" >&2
  docker logs --tail 40 tailscale >&2 || true
  printf '%s\n' "---- end ----" >&2
  fail "tailscale0 missing — kernel mode not active"
fi
ok "tailscale0 interface present"

# Confirm it has a tailnet IP
TS_IP=""
for i in $(seq 1 30); do
  TS_IP=$(docker exec tailscale tailscale ip -4 2>/dev/null | head -1 || true)
  [ -n "$TS_IP" ] && break
  sleep 2
done

if [ -z "$TS_IP" ]; then
  warn "tailscale0 exists but no IP assigned yet"
  docker exec tailscale tailscale status >&2 || true
  fail "tailscale not connected"
fi
ok "tailscale connected: ${TS_IP}"

# ---------------------------------------------------------------------------
# 5. Start Portainer
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
  >/dev/null 2>&1 || fail "portainer docker run failed"

sleep 3
if [ "$(docker inspect -f '{{.State.Status}}' portainer 2>/dev/null)" != "running" ]; then
  docker logs --tail 20 portainer >&2 || true
  fail "portainer not running"
fi
ok "portainer running"

docker image prune -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6. Final check — nothing respawned the tailscale container
# ---------------------------------------------------------------------------
step "final verification"
sleep 5
FINAL_MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' tailscale 2>/dev/null || echo "missing")
[ "$FINAL_MODE" = "host" ] || fail "tailscale re-created on '${FINAL_MODE}'"
[ -n "$(docker exec tailscale tailscale ip -4 2>/dev/null || true)" ] || fail "tailscale lost connection"

status "tailscale IP: ${TS_IP}"
status "portainer: https://${TS_IP}:9443"
ok "init done"
exit 0
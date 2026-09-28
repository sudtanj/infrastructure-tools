#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh

set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"

echo "[*] init start"

# Mask systemd unit so it can never respawn the container
sudo systemctl mask containers.service 2>/dev/null || true
sudo systemctl stop containers.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/containers.service
sudo systemctl daemon-reload 2>/dev/null || true
echo "[+] systemd unit masked"

# Remove all containers and the bridge network
docker rm -f tailscale portainer ts-sidecar ts-proxy 2>/dev/null || true
docker network rm tailscale-net 2>/dev/null || true
echo "[+] cleanup done"

# Start tailscale on host network
if [ -n "$TS_AUTHKEY" ]; then
  TS_AUTH_ENV="-e TS_AUTHKEY=${TS_AUTHKEY}"
else
  TS_AUTH_ENV=""
fi

# shellcheck disable=SC2086
docker run -d --name tailscale --restart always \
  --network=host \
  -e GOGC=10 -e GOMEMLIMIT=80MiB \
  $TS_AUTH_ENV \
  -e TS_STATE_DIR=/var/lib/tailscale \
  -e TS_USERSPACE=true \
  -e TS_HOSTNAME="${TS_HOSTNAME}" \
  -e TS_EXTRA_ARGS="--advertise-tags=tag:home" \
  -e TS_AUTH_ONCE=true \
  -e TS_ACCEPT_DNS=true \
  -e TS_SOCKS5_SERVER=0.0.0.0:1055 \
  -e TS_OUTBOUND_HTTP_PROXY_LISTEN=0.0.0.0:1055 \
  -e TZ=Asia/Jakarta \
  -v /var/lib/tailscale:/var/lib/tailscale \
  tailscale/tailscale:latest >/dev/null 2>&1

sleep 3

# Verify host network
NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' tailscale 2>/dev/null || echo "missing")
echo "[+] network mode: ${NETMODE}"
if [ "$NETMODE" != "host" ]; then
  echo "[x] not on host network — aborting" >&2
  exit 1
fi

# Verify IPv6 inside
if ! docker exec tailscale sh -c 'ip -6 addr show scope global | grep -q inet6'; then
  echo "[x] no IPv6 in container" >&2
  docker exec tailscale ip -6 addr show >&2 || true
  exit 1
fi
echo "[+] IPv6 visible"

# Wait for connection
echo "[*] waiting for connection"
READY=0
for i in $(seq 1 60); do
  if docker exec tailscale tailscale ip -4 >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done

if [ "$READY" -ne 1 ]; then
  echo "[x] tailscale did not connect" >&2
  docker logs --tail 30 tailscale >&2 || true
  exit 1
fi
echo "[+] tailscale connected"

# Start portainer
docker run -d --name portainer --restart always \
  --network bridge \
  -p 9000:9000 -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest \
  --snapshot-interval=15m >/dev/null 2>&1
echo "[+] portainer running"

# Final check — nothing recreated the container
sleep 10
FINAL=$(docker inspect -f '{{.HostConfig.NetworkMode}}' tailscale 2>/dev/null || echo "missing")
if [ "$FINAL" != "host" ]; then
  echo "[x] recreated on '${FINAL}'" >&2
  exit 1
fi

echo "[+] init done"
exit 0
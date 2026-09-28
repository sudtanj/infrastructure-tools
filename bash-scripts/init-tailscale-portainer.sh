#!/bin/bash
# bash-scripts/init-tailscale-portainer.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Tailscale = static binary on host (kernel mode). Portainer = Docker. No Tailscale container.

set -euo pipefail

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"

TS_BIN_DIR="/mnt/disks/tailscale"
TS_STATE_DIR="/var/lib/tailscale"
TS_SOCKET="/run/tailscale/tailscaled.sock"
TS_VERSION="1.68.1"

echo "[*] init start"

# ---------------------------------------------------------------------------
# 0. Remove any old Tailscale containers / systemd units
# ---------------------------------------------------------------------------
echo "[>] removing old tailscale containers and units"
docker rm -f tailscale ts-sidecar ts-proxy 2>/dev/null || true
docker network rm tailscale-net 2>/dev/null || true
sudo systemctl mask containers.service 2>/dev/null || true
sudo systemctl stop containers.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/containers.service
echo "[+] cleanup done"

# ---------------------------------------------------------------------------
# 1. Ensure /dev/net/tun exists (needed for kernel mode)
# ---------------------------------------------------------------------------
echo "[>] ensuring /dev/net/tun"
if [ ! -e /dev/net/tun ]; then
  sudo mkdir -p /dev/net
  sudo mknod /dev/net/tun c 10 200
  sudo chmod 666 /dev/net/tun
fi
echo "[+] tun ready"

# ---------------------------------------------------------------------------
# 2. Mount executable tmpfs for the binary
#    COS mounts /var and most of /mnt/disks as noexec, but a tmpfs on top
#    of a directory is exec. This is the only place we can run the binary.
# ---------------------------------------------------------------------------
echo "[>] preparing executable binary directory"
sudo mkdir -p "$TS_BIN_DIR"
if ! mountpoint -q "$TS_BIN_DIR"; then
  sudo mount -t tmpfs -o exec,mode=0755 tmpfs "$TS_BIN_DIR"
fi
echo "[+] tmpfs mounted at ${TS_BIN_DIR}"

# ---------------------------------------------------------------------------
# 3. Download static Tailscale binary if not present
# ---------------------------------------------------------------------------
echo "[>] installing tailscale binary"
if [ ! -x "${TS_BIN_DIR}/tailscaled" ]; then
  ARCH="amd64"
  TARBALL="tailscale_${TS_VERSION}_${ARCH}.tgz"
  URL="https://pkgs.tailscale.com/stable/${TARBALL}"
  TMP="/var/tmp/${TARBALL}"

  [ -f "$TMP" ] || curl -fsSL -o "$TMP" "$URL"

  sudo tar -xzf "$TMP" -C "$TS_BIN_DIR" --strip-components=1 \
    "tailscale_${TS_VERSION}_${ARCH}/tailscale" \
    "tailscale_${TS_VERSION}_${ARCH}/tailscaled"

  sudo chmod +x "${TS_BIN_DIR}/tailscaled" "${TS_BIN_DIR}/tailscale"
  rm -f "$TMP"
fi
echo "[+] binary ready"

# ---------------------------------------------------------------------------
# 4. Prepare state directory
# ---------------------------------------------------------------------------
sudo mkdir -p "$TS_STATE_DIR"
sudo chmod 700 "$TS_STATE_DIR"
sudo mkdir -p /run/tailscale
sudo chmod 755 /run/tailscale

# ---------------------------------------------------------------------------
# 5. Write systemd unit for tailscaled (kernel mode, no --tun=userspace)
# ---------------------------------------------------------------------------
echo "[>] writing tailscaled.service"
sudo tee /etc/systemd/system/tailscaled.service >/dev/null <<EOF
[Unit]
Description=Tailscale node agent
Wants=network-pre.target
After=network-pre.target
Before=network.target

[Service]
Type=notify
ExecStartPre=${TS_BIN_DIR}/tailscaled --cleanup
ExecStart=${TS_BIN_DIR}/tailscaled \\
  --state=${TS_STATE_DIR}/tailscaled.state \\
  --socket=${TS_SOCKET} \\
  --port=41641
ExecStopPost=${TS_BIN_DIR}/tailscaled --cleanup
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tailscaled.service >/dev/null 2>&1
sudo systemctl restart tailscaled.service
sleep 5

# ---------------------------------------------------------------------------
# 6. Verify tailscaled is up and running in kernel mode
# ---------------------------------------------------------------------------
echo "[>] verifying tailscaled"
if ! sudo systemctl is-active --quiet tailscaled.service; then
  echo "[x] tailscaled not running" >&2
  sudo journalctl -u tailscaled.service -n 30 --no-pager >&2 || true
  exit 1
fi
echo "[+] tailscaled running"

# ---------------------------------------------------------------------------
# 7. Authenticate if not already connected
# ---------------------------------------------------------------------------
echo "[>] checking tailscale connection"
if sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" status >/dev/null 2>&1; then
  echo "[+] already connected"
else
  if [ -z "$TS_AUTHKEY" ]; then
    echo "[x] not connected and no TS_AUTHKEY provided" >&2
    exit 1
  fi
  sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$TS_HOSTNAME" \
    --advertise-tags=tag:home \
    --accept-dns=true \
    --accept-routes=false
  sleep 3
fi

# Verify connection
if ! sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" ip -4 >/dev/null 2>&1; then
  echo "[x] tailscale did not connect" >&2
  sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" status >&2 || true
  exit 1
fi
echo "[+] tailscale connected"

# ---------------------------------------------------------------------------
# 8. Verify tailscale0 interface exists (proves kernel mode)
# ---------------------------------------------------------------------------
echo "[>] verifying tailscale0 interface"
if ! ip link show tailscale0 >/dev/null 2>&1; then
  echo "[x] tailscale0 interface missing — not in kernel mode" >&2
  exit 1
fi
echo "[+] tailscale0 interface present"

# ---------------------------------------------------------------------------
# 9. Start Portainer
# ---------------------------------------------------------------------------
echo "[>] starting portainer"
docker rm -f portainer >/dev/null 2>&1 || true
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

sleep 3
if [ "$(docker inspect -f '{{.State.Status}}' portainer 2>/dev/null)" != "running" ]; then
  echo "[x] portainer not running" >&2
  docker logs --tail 20 portainer >&2 || true
  exit 1
fi
echo "[+] portainer running"

docker image prune -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 10. Final state
# ---------------------------------------------------------------------------
echo "[>] summary"
TS_IP=$(sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" ip -4 | head -1)
echo "[*] tailscale IP: ${TS_IP}"
echo "[*] portainer: http://[${TS_IP}]:9000"
echo "[+] init done"
exit 0
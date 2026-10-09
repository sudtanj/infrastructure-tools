#!/bin/bash
# bash-scripts/update-tailscale.sh
# Update the Tailscale binaries installed by terraform_free_tier_gcp/cloud-init.yaml.tftpl.
# Uses the same paths as cloud-init (/var/lib/docker/tailscale-bin) and keeps the existing
# systemd unit and node auth untouched. Set TS_VERSION to pin a version (default: latest stable).

set -euo pipefail

TS_BIN_DIR="/var/lib/docker/tailscale-bin"
TS_SOCKET="/run/tailscale/tailscaled.sock"
TS_CACHE_DIR="/var/tmp"
TS_VERSION="${TS_VERSION:-}"

# Free-tier e2-micro: run at lowest CPU/IO priority so the update does not starve the VM
renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ 2>/dev/null || true

echo "[*] update-tailscale start"

[ -x "${TS_BIN_DIR}/tailscaled" ] || { echo "[x] ${TS_BIN_DIR}/tailscaled not found; run cloud-init first" >&2; exit 1; }

# --- Target version ---
if [ -z "$TS_VERSION" ]; then
  echo "[>] fetching latest version"
  TS_VERSION=$(curl -fsSL https://pkgs.tailscale.com/stable/ \
    | grep -oE 'tailscale_[0-9]+\.[0-9]+\.[0-9]+_amd64\.tgz' \
    | sort -V | tail -1 \
    | sed -E 's/tailscale_([0-9]+\.[0-9]+\.[0-9]+)_amd64\.tgz/\1/')
fi
[ -n "$TS_VERSION" ] || { echo "[x] cannot determine target version" >&2; exit 1; }

INSTALLED=$("${TS_BIN_DIR}/tailscaled" --version 2>/dev/null | head -1 | awk '{print $1}' || true)
echo "[+] installed: ${INSTALLED:-unknown}, target: ${TS_VERSION}"

if [ "$INSTALLED" = "$TS_VERSION" ]; then
  echo "[+] already up to date"
  exit 0
fi

# --- Download and extract to a staging dir ---
STAGE=$(sudo mktemp -d "${TS_CACHE_DIR}/tailscale-update.XXXXXX")
trap 'sudo rm -rf "$STAGE"' EXIT

dirname="tailscale_${TS_VERSION}_amd64"
tarname="${dirname}.tgz"
echo "[>] downloading ${tarname}"
sudo curl -fsSLo "${STAGE}/${tarname}" "https://pkgs.tailscale.com/stable/${tarname}"
sudo tar -xzf "${STAGE}/${tarname}" -C "$STAGE" --strip-components=1 \
  "${dirname}/tailscale" "${dirname}/tailscaled"
sudo chmod 755 "${STAGE}/tailscale" "${STAGE}/tailscaled"

NEW=$("${STAGE}/tailscaled" --version 2>/dev/null | head -1 | awk '{print $1}' || true)
[ "$NEW" = "$TS_VERSION" ] || { echo "[x] downloaded binary reports '${NEW}', expected ${TS_VERSION}" >&2; exit 1; }

# --- Swap binaries, rolling back on failure ---
rollback() {
  echo "[!] rolling back to ${INSTALLED}" >&2
  sudo mv -f "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscaled" 2>/dev/null || true
  sudo mv -f "${TS_BIN_DIR}/tailscale.bak" "${TS_BIN_DIR}/tailscale" 2>/dev/null || true
  sudo systemctl restart tailscaled.service || true
}

# Same resource limits as cloud-init (drop-in so the cloud-init unit stays untouched)
sudo mkdir -p /etc/systemd/system/tailscaled.service.d
sudo tee /etc/systemd/system/tailscaled.service.d/10-free-tier.conf >/dev/null <<DROPIN
[Service]
Nice=10
CPUWeight=50
CPUQuota=50%
MemoryHigh=96M
Environment=GOGC=50
Environment=GOMEMLIMIT=80MiB
DROPIN

echo "[>] stopping tailscaled"
sudo systemctl stop tailscaled.service || true
sudo cp -a "${TS_BIN_DIR}/tailscaled" "${TS_BIN_DIR}/tailscaled.bak"
sudo cp -a "${TS_BIN_DIR}/tailscale" "${TS_BIN_DIR}/tailscale.bak"
sudo mv -f "${STAGE}/tailscaled" "${TS_BIN_DIR}/tailscaled"
sudo mv -f "${STAGE}/tailscale" "${TS_BIN_DIR}/tailscale"

echo "[>] starting tailscaled"
sudo systemctl daemon-reload
sudo systemctl enable tailscaled.service >/dev/null 2>&1 || true
if ! sudo systemctl restart tailscaled.service; then
  echo "[x] tailscaled failed to start" >&2
  sudo journalctl -u tailscaled.service -n 30 --no-pager >&2 || true
  rollback
  exit 1
fi

# Wait for the daemon to answer on its socket
for _ in $(seq 1 15); do
  sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" version >/dev/null 2>&1 && break
  sleep 1
done
if ! sudo systemctl is-active --quiet tailscaled.service; then
  echo "[x] tailscaled not running after update" >&2
  rollback
  exit 1
fi

sudo rm -f "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscale.bak"

# --- Summary ---
echo "[>] summary"
echo "[*] version: ${INSTALLED} -> $("${TS_BIN_DIR}/tailscaled" --version | head -1 | awk '{print $1}')"
if TS_IP=$(sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" ip -4 2>/dev/null | head -1) && [ -n "$TS_IP" ]; then
  echo "[*] tailscale ip: ${TS_IP}"
else
  echo "[!] node not authenticated (run init-tailscale or tailscale up)" >&2
fi
echo "[+] update-tailscale done"

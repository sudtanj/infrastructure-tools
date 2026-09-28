#!/bin/bash
# bash-scripts/update-tailscale.sh
# Updates the static Tailscale binary to the latest stable release.
# Restarts tailscaled with the new binary. Preserves auth state.
# Idempotent — safe to run repeatedly.

set -euo pipefail

TS_BIN_DIR="/var/lib/docker/tailscale-bin"
TS_INSTALLER="/tmp/install-tailscale.sh"
TS_CURRENT=""

echo "[*] update-tailscale start"

# --- Sanity checks ---
if [ ! -d "$TS_BIN_DIR" ]; then
  echo "[x] ${TS_BIN_DIR} does not exist — Tailscale was never installed" >&2
  exit 1
fi

if [ ! -x "${TS_BIN_DIR}/tailscale" ]; then
  echo "[x] ${TS_BIN_DIR}/tailscale missing — reinstall required" >&2
  exit 1
fi

# --- Current version ---
if [ -x "${TS_BIN_DIR}/tailscaled" ]; then
  TS_CURRENT=$("${TS_BIN_DIR}/tailscaled" --version 2>/dev/null | awk '{print $1}' || echo "unknown")
  echo "[+] current version: ${TS_CURRENT}"
fi

# --- Latest version from the Tailscale CDN ---
# The stable directory lists all available tarballs. Grab the newest one.
echo "[>] fetching latest version"
LATEST=$(curl -fsSL https://pkgs.tailscale.com/stable/ \
  | grep -oE 'tailscale_[0-9]+\.[0-9]+\.[0-9]+_amd64\.tgz' \
  | sort -V \
  | tail -1 \
  | sed -E 's/tailscale_([0-9]+\.[0-9]+\.[0-9]+)_amd64\.tgz/\1/')

if [ -z "$LATEST" ]; then
  echo "[x] could not determine latest version" >&2
  exit 1
fi
echo "[+] latest version: ${LATEST}"

# --- Compare ---
if [ "$TS_CURRENT" = "$LATEST" ]; then
  echo "[+] already up to date — no action needed"
  echo "[+] update-tailscale done"
  exit 0
fi

echo "[>] updating from ${TS_CURRENT} to ${LATEST}"

# --- Stop tailscaled ---
echo "[>] stopping tailscaled"
sudo systemctl stop tailscaled.service
sleep 2

# --- Back up current binary in case update fails ---
sudo cp -a "${TS_BIN_DIR}/tailscaled" "${TS_BIN_DIR}/tailscaled.bak" 2>/dev/null || true
sudo cp -a "${TS_BIN_DIR}/tailscale"  "${TS_BIN_DIR}/tailscale.bak"  2>/dev/null || true

# --- Install new version ---
if [ ! -x "$TS_INSTALLER" ]; then
  echo "[!] ${TS_INSTALLER} missing — writing a minimal installer"
  sudo tee "$TS_INSTALLER" >/dev/null <<'INSTALLER'
#!/bin/bash
set -euo pipefail
VERSION="$1"
DEST="$2"
TMPDIR="${TMPDIR:-/var/tmp}"
dirname="tailscale_${VERSION}_amd64"
tarname="${dirname}.tgz"
if [[ ! -e "$TMPDIR/$tarname" ]]; then
  mkdir -p "$TMPDIR"
  curl -fsSLo "$TMPDIR/$tarname" \
    "https://pkgs.tailscale.com/stable/$tarname"
fi
mkdir -p "$DEST"
tar -xzf "$TMPDIR/$tarname" -C "$DEST" --strip-components=1 \
  "$dirname/tailscale" "$dirname/tailscaled"
chmod +x "$DEST/tailscale" "$DEST/tailscaled"
INSTALLER
  sudo chmod +x "$TS_INSTALLER"
fi

if ! sudo TMPDIR=/var/tmp bash "$TS_INSTALLER" "$LATEST" "$TS_BIN_DIR"; then
  echo "[x] install failed — rolling back" >&2
  sudo mv "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscaled" 2>/dev/null || true
  sudo mv "${TS_BIN_DIR}/tailscale.bak"  "${TS_BIN_DIR}/tailscale"  2>/dev/null || true
  sudo systemctl start tailscaled.service
  exit 1
fi

# --- Verify the new binary runs ---
if ! "${TS_BIN_DIR}/tailscaled" --version >/dev/null 2>&1; then
  echo "[x] new binary cannot execute — rolling back" >&2
  sudo mv "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscaled"
  sudo mv "${TS_BIN_DIR}/tailscale.bak"  "${TS_BIN_DIR}/tailscale"
  sudo systemctl start tailscaled.service
  exit 1
fi

NEW=$("${TS_BIN_DIR}/tailscaled" --version 2>/dev/null | awk '{print $1}')
echo "[+] installed version: ${NEW}"

# --- Restart tailscaled ---
echo "[>] starting tailscaled"
sudo systemctl start tailscaled.service
sleep 5

# --- Verify it's running and connected ---
if ! sudo systemctl is-active --quiet tailscaled.service; then
  echo "[x] tailscaled failed to start" >&2
  sudo journalctl -u tailscaled.service -n 30 --no-pager >&2 || true
  exit 1
fi
echo "[+] tailscaled running"

if ip link show tailscale0 >/dev/null 2>&1; then
  echo "[+] tailscale0 interface present"
else
  echo "[!] tailscale0 missing — check 'tailscale status'" >&2
fi

# --- Clean up backup files ---
sudo rm -f "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscale.bak"

# --- Version report ---
FINAL=$("${TS_BIN_DIR}/tailscaled" --version 2>/dev/null | awk '{print $1}')
echo "[+] update-tailscale done — ${TS_CURRENT} -> ${FINAL}"
exit 0

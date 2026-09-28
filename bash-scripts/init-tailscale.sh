#!/bin/bash
# bash-scripts/upsert-tailscale.sh
# Upsert Tailscale. Handles COS noexec by mounting tmpfs on the bin dir.
# Idempotent: install / update / no-op depending on state.

set -euo pipefail

TS_BIN_DIR="/var/lib/docker/tailscale-bin"
TS_STATE_DIR="/var/lib/tailscale"
TS_SOCKET="/run/tailscale/tailscaled.sock"
TS_UNIT="/etc/systemd/system/tailscaled.service"
TS_INSTALLER="/tmp/install-tailscale.sh"
TS_CACHE_DIR="/var/cache/tailscale"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
TS_AUTHKEY="${TS_AUTHKEY:-}"

echo "[*] upsert-tailscale start"

# ---------------------------------------------------------------------------
# 1. Ensure bin dir exists and is executable (tmpfs mount)
# ---------------------------------------------------------------------------
echo "[>] ensuring executable bin directory"
sudo mkdir -p "$TS_BIN_DIR"
if ! sudo mountpoint -q "$TS_BIN_DIR"; then
  echo "[>] mounting tmpfs (exec) on ${TS_BIN_DIR}"
  sudo mount -t tmpfs -o exec,mode=0755 tmpfs "$TS_BIN_DIR"
fi
echo "[+] bin dir ready"

# ---------------------------------------------------------------------------
# 2. Persistent tarball cache (so re-installs skip the download)
# ---------------------------------------------------------------------------
sudo mkdir -p "$TS_CACHE_DIR"

# ---------------------------------------------------------------------------
# 3. Determine latest version
# ---------------------------------------------------------------------------
echo "[>] fetching latest version"
LATEST=$(curl -fsSL https://pkgs.tailscale.com/stable/ \
  | grep -oE 'tailscale_[0-9]+\.[0-9]+\.[0-9]+_amd64\.tgz' \
  | sort -V | tail -1 \
  | sed -E 's/tailscale_([0-9]+\.[0-9]+\.[0-9]+)_amd64\.tgz/\1/')

[ -n "$LATEST" ] || { echo "[x] cannot determine latest version" >&2; exit 1; }
echo "[+] latest: ${LATEST}"

# ---------------------------------------------------------------------------
# 4. Detect current state
# ---------------------------------------------------------------------------
INSTALLED=""
if [ -x "${TS_BIN_DIR}/tailscaled" ]; then
  INSTALLED=$("${TS_BIN_DIR}/tailscaled" --version 2>/dev/null | awk '{print $1}' || echo "")
fi

if [ -z "$INSTALLED" ]; then
  echo "[+] current: not installed"
  ACTION="install"
elif [ "$INSTALLED" = "$LATEST" ]; then
  echo "[+] current: ${INSTALLED} — already up to date"
  ACTION="none"
else
  echo "[+] current: ${INSTALLED} — update available"
  ACTION="update"
fi

# ---------------------------------------------------------------------------
# 5. Write installer if missing
# ---------------------------------------------------------------------------
if [ ! -x "$TS_INSTALLER" ]; then
  echo "[>] writing installer to ${TS_INSTALLER}"
  sudo tee "$TS_INSTALLER" >/dev/null <<'INSTALLER'
#!/bin/bash
set -euo pipefail
VERSION="$1"
DEST="$2"
TMPDIR="${TMPDIR:-/var/cache/tailscale}"
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

# ---------------------------------------------------------------------------
# 6. Install or update
# ---------------------------------------------------------------------------
if [ "$ACTION" != "none" ]; then
  if [ "$ACTION" = "update" ]; then
    echo "[>] stopping tailscaled for update"
    sudo systemctl stop tailscaled.service 2>/dev/null || true
    sleep 2
    sudo cp -a "${TS_BIN_DIR}/tailscaled" "${TS_BIN_DIR}/tailscaled.bak" 2>/dev/null || true
    sudo cp -a "${TS_BIN_DIR}/tailscale"  "${TS_BIN_DIR}/tailscale.bak"  2>/dev/null || true
  fi

  echo "[>] installing ${LATEST}"
  if ! sudo TMPDIR="$TS_CACHE_DIR" bash "$TS_INSTALLER" "$LATEST" "$TS_BIN_DIR"; then
    echo "[x] install failed" >&2
    if [ "$ACTION" = "update" ]; then
      sudo mv "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscaled" 2>/dev/null || true
      sudo mv "${TS_BIN_DIR}/tailscale.bak"  "${TS_BIN_DIR}/tailscale"  2>/dev/null || true
      sudo systemctl start tailscaled.service || true
    fi
    exit 1
  fi

  if ! "${TS_BIN_DIR}/tailscaled" --version >/dev/null 2>&1; then
    echo "[x] new binary won't execute" >&2
    echo "--- debug ---" >&2
    file "${TS_BIN_DIR}/tailscaled" >&2 || true
    mount | grep "$TS_BIN_DIR" >&2 || echo "(no tmpfs mount)" >&2
    ls -la "$TS_BIN_DIR" >&2 || true
    if [ "$ACTION" = "update" ]; then
      sudo mv "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscaled"
      sudo mv "${TS_BIN_DIR}/tailscale.bak"  "${TS_BIN_DIR}/tailscale"
      sudo systemctl start tailscaled.service || true
    fi
    exit 1
  fi

  sudo rm -f "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscale.bak"
  echo "[+] binary ready"
else
  echo "[+] binary already correct"
fi

# ---------------------------------------------------------------------------
# 7. State and socket directories
# ---------------------------------------------------------------------------
sudo mkdir -p "$TS_STATE_DIR"
sudo chmod 700 "$TS_STATE_DIR"
sudo mkdir -p /run/tailscale
sudo chmod 755 /run/tailscale

# ---------------------------------------------------------------------------
# 8. Systemd unit
# ---------------------------------------------------------------------------
WANT_UNIT=1
if [ -f "$TS_UNIT" ] && grep -q "ExecStart=${TS_BIN_DIR}/tailscaled" "$TS_UNIT" 2>/dev/null; then
  WANT_UNIT=0
fi

if [ "$WANT_UNIT" = "1" ]; then
  echo "[>] writing ${TS_UNIT}"
  sudo tee "$TS_UNIT" >/dev/null <<UNIT
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
RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0750
CacheDirectory=tailscale
CacheDirectoryMode=0750

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
else
  echo "[+] systemd unit already correct"
fi

sudo systemctl enable tailscaled.service >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 9. Service
# ---------------------------------------------------------------------------
if [ "$ACTION" != "none" ] || ! sudo systemctl is-active --quiet tailscaled.service; then
  echo "[>] starting tailscaled"
  sudo systemctl restart tailscaled.service
  sleep 5
fi

if ! sudo systemctl is-active --quiet tailscaled.service; then
  echo "[x] tailscaled not running" >&2
  sudo journalctl -u tailscaled.service -n 30 --no-pager >&2 || true
  exit 1
fi
echo "[+] tailscaled running"

# ---------------------------------------------------------------------------
# 10. Authenticate if not already
# ---------------------------------------------------------------------------
if sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" ip -4 >/dev/null 2>&1; then
  TS_IP=$(sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" ip -4 | head -1)
  echo "[+] already authenticated: ${TS_IP}"
else
  if [ -z "$TS_AUTHKEY" ]; then
    echo "[!] not authenticated and TS_AUTHKEY not set" >&2
  else
    echo "[>] authenticating"
    sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" up \
      --authkey="$TS_AUTHKEY" \
      --hostname="$TS_HOSTNAME" \
      --advertise-tags=tag:home \
      --accept-dns=true \
      --accept-routes=false

    if ! sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" ip -4 >/dev/null 2>&1; then
      echo "[x] authentication failed" >&2
      sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" status >&2 || true
      exit 1
    fi
    TS_IP=$(sudo "${TS_BIN_DIR}/tailscale" --socket="$TS_SOCKET" ip -4 | head -1)
    echo "[+] authenticated: ${TS_IP}"
  fi
fi

# ---------------------------------------------------------------------------
# 11. Summary
# ---------------------------------------------------------------------------
FINAL=$("${TS_BIN_DIR}/tailscaled" --version 2>/dev/null | awk '{print $1}')
echo "[>] summary"
echo "[*] action: ${ACTION}"
echo "[*] version: ${FINAL}"
if ip link show tailscale0 >/dev/null 2>&1; then
  echo "[*] interface: tailscale0 present"
else
  echo "[*] interface: missing" >&2
fi
echo "[+] upsert-tailscale done"
exit 0

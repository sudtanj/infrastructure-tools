#!/bin/bash
# fix-dns64.sh
# Configures the VM to use Google's public DNS64 resolver so that IPv6-only
# hosts can reach IPv4-only services like GitHub's API.

set -euo pipefail

RESOLV_CONF="/etc/resolv.conf"
BACKUP_SUFFIX=".bak.$(date +%Y%m%d_%H%M%S)"

echo "[*] Starting DNS64 configuration..."

# 1. Check for root
if [ "$EUID" -ne 0 ]; then
  echo "[x] This script must be run as root. Use: sudo bash $0" >&2
  exit 1
fi

# 2. Unlock resolv.conf if it's locked (from previous attempts)
chattr -i "$RESOLV_CONF" 2>/dev/null || true

# 3. Backup existing resolv.conf
if [ -f "$RESOLV_CONF" ] || [ -L "$RESOLV_CONF" ]; then
    cp -L "$RESOLV_CONF" "${RESOLV_CONF}${BACKUP_SUFFIX}"
    echo "[+] Backed up current resolv.conf to ${RESOLV_CONF}${BACKUP_SUFFIX}"
else
    echo "[!] No existing resolv.conf found to backup."
fi

# 4. Stop systemd-resolved from managing resolv.conf
if systemctl is-active --quiet systemd-resolved; then
    echo "[>] Stopping and disabling systemd-resolved..."
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved 2>/dev/null || true
    echo "[+] systemd-resolved stopped."
else
    echo "[*] systemd-resolved is not active."
fi

# 5. Write new resolv.conf with Google DNS64 servers
echo "[>] Writing new resolv.conf with Google DNS64 servers..."
rm -f "$RESOLV_CONF"
cat > "$RESOLV_CONF" << 'EOF'
# Google Public DNS64
nameserver 2001:4860:4860::6464
nameserver 2001:4860:4860::64
EOF

# 6. Lock the file to prevent overwriting (optional but recommended)
if chattr +i "$RESOLV_CONF" 2>/dev/null; then
    echo "[+] Locked resolv.conf with chattr +i."
else
    echo "[!] Could not lock resolv.conf (filesystem may not support it)."
fi

echo "[+] DNS64 configuration complete."

# 7. Verify connectivity to GitHub
echo ""
echo "[>] Testing connectivity to api.github.com (this may take a moment)..."
if curl -6 -s -f -m 15 https://api.github.com > /dev/null; then
    echo "[+] SUCCESS: api.github.com is reachable!"
else
    echo "[x] FAILURE: Still cannot reach api.github.com."
    echo "    DNS64 alone may not be enough. Your network requires a NAT64 gateway."
    echo "    Consider using a public NAT64 service like nat64.net or level66.services."
    exit 1
fi

echo ""
echo "[*] Done. You can now restart your GitHub runner container."

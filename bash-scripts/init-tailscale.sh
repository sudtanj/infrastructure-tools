#!/bin/bash
# bash-scripts/upsert-tailscale.sh
# Low-footprint Tailscale upsert for tiny VMs (e2-micro / COS).
#
# Env: TS_AUTHKEY, TS_HOSTNAME, TS_BIN_DIR, TS_EXTRA_ARGS,
#      TS_CHECK_MINUTES (default 720), FORCE=1 (skip the check interval)

set -euo pipefail

# Run this script itself at the lowest CPU/IO priority (best effort)
renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

# Skip sudo (extra process) when already root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

TS_BIN_DIR="${TS_BIN_DIR:-}"
TS_DEFAULT_BIN_DIR="/var/lib/docker/tailscale-bin"   # boot disk: persistent, no RAM
TS_STATE_DIR="/var/lib/tailscale"
TS_SOCKET="/run/tailscale/tailscaled.sock"
TS_UNIT="/etc/systemd/system/tailscaled.service"
TS_CACHE_DIR="/var/cache/tailscale"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_CHECK_MINUTES="${TS_CHECK_MINUTES:-720}"
STAMP="${TS_CACHE_DIR}/.last-check"

# Reuse an existing install before falling back to the default
if [ -z "$TS_BIN_DIR" ]; then
  UNIT_BIN=$(systemctl show tailscaled.service -p ExecStart 2>/dev/null | grep -oE "path=[^ ;]+tailscaled" | head -1 | cut -d= -f2 || true)
  for d in "${UNIT_BIN:+$(dirname "$UNIT_BIN")}" /var/lib/docker/tailscale-bin /var/lib/cloud/tailscale-bin; do
    if [ -n "$d" ] && [ -x "$d/tailscaled" ]; then TS_BIN_DIR="$d"; break; fi
  done
  TS_BIN_DIR="${TS_BIN_DIR:-$TS_DEFAULT_BIN_DIR}"
fi

echo "[*] upsert-tailscale start"
echo "[+] using ${TS_BIN_DIR}"

# ---------- helpers ----------
exec_ok() {  # can binaries run from this directory?
  local t="$1/.exec-test" rc=1
  $SUDO sh -c "printf '#!/bin/sh\nexit 0\n' > '$t' && chmod 755 '$t'" || return 1
  if "$t" >/dev/null 2>&1; then rc=0; fi
  $SUDO rm -f "$t"
  return $rc
}

installed_version() {
  "${TS_BIN_DIR}/tailscaled" --version 2>/dev/null | head -n1 | awk '{print $1}' || true
}

fetch_latest() {
  local v
  # Tiny JSON endpoint instead of scraping the full HTML index
  v=$(curl -fsSL --max-time 20 'https://pkgs.tailscale.com/stable/?mode=json' 2>/dev/null \
      | grep -oE '"TarballsVersion"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [ -z "$v" ]; then
    v=$(curl -fsSL --max-time 20 https://pkgs.tailscale.com/stable/ 2>/dev/null \
        | grep -oE 'tailscale_[0-9]+\.[0-9]+\.[0-9]+_amd64\.tgz' | sort -uV | tail -1 \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  fi
  echo "$v"
}

install_ts() {  # install_ts <version> <dest>
  local ver="$1" dest="$2" dn tgz
  dn="tailscale_${ver}_amd64"
  tgz="${TS_CACHE_DIR}/${dn}.tgz"
  if [ ! -s "$tgz" ]; then
    $SUDO curl -fsSL --max-time 300 -o "$tgz" "https://pkgs.tailscale.com/stable/${dn}.tgz" \
      || { $SUDO rm -f "$tgz"; return 1; }
  fi
  $SUDO tar -xzf "$tgz" -C "$dest" --strip-components=1 "${dn}/tailscale" "${dn}/tailscaled" || return 1
  $SUDO chmod 755 "$dest/tailscale" "$dest/tailscaled" || return 1
  # Keep only the current tarball on disk
  $SUDO find "$TS_CACHE_DIR" -maxdepth 1 -name 'tailscale_*_amd64.tgz' ! -name "${dn}.tgz" -delete || true
}

restore_backup() {
  for b in tailscaled tailscale; do
    if [ -e "${TS_BIN_DIR}/${b}.bak" ]; then $SUDO mv -f "${TS_BIN_DIR}/${b}.bak" "${TS_BIN_DIR}/${b}" || true; fi
  done
  $SUDO systemctl start tailscaled.service || true
}

# ---------- executable bin dir ----------
echo "[>] ensuring executable bin directory"
$SUDO mkdir -p "$TS_BIN_DIR" "$TS_CACHE_DIR"
$SUDO chmod 755 "$TS_BIN_DIR"
# Only use RAM-backed tmpfs if the disk location is noexec
if ! exec_ok "$TS_BIN_DIR" && ! mountpoint -q "$TS_BIN_DIR"; then
  echo "[!] ${TS_BIN_DIR} is noexec; falling back to tmpfs (uses RAM)"
  $SUDO mount -t tmpfs -o exec,mode=0755,size=64m tmpfs "$TS_BIN_DIR"
fi
echo "[+] bin dir ready"

# ---------- current vs latest ----------
INSTALLED=""
if [ -x "${TS_BIN_DIR}/tailscaled" ]; then INSTALLED=$(installed_version); fi

if [ -n "$INSTALLED" ] && [ -z "${FORCE:-}" ] \
   && [ -n "$(find "$STAMP" -mmin -"$TS_CHECK_MINUTES" 2>/dev/null)" ]; then
  echo "[+] current: ${INSTALLED} (checked within ${TS_CHECK_MINUTES}m; skipping network check)"
  LATEST="$INSTALLED"
  ACTION="none"
else
  echo "[>] fetching latest version"
  LATEST=$(fetch_latest)
  if [ -z "$LATEST" ]; then
    if [ -n "$INSTALLED" ]; then
      echo "[!] cannot determine latest version; keeping ${INSTALLED}" >&2
      LATEST="$INSTALLED"
    else
      echo "[x] cannot determine latest version" >&2; exit 1
    fi
  fi
  echo "[+] latest: ${LATEST}"
  $SUDO touch "$STAMP"

  if [ -z "$INSTALLED" ]; then
    echo "[+] current: not installed"; ACTION="install"
  elif [ "$INSTALLED" = "$LATEST" ]; then
    echo "[+] current: ${INSTALLED} — already up to date"; ACTION="none"
  else
    echo "[+] current: ${INSTALLED} — update available"; ACTION="update"
  fi
fi

# ---------- install / update ----------
if [ "$ACTION" != "none" ]; then
  if [ "$ACTION" = "update" ]; then
    echo "[>] stopping tailscaled for update"
    $SUDO systemctl stop tailscaled.service 2>/dev/null || true
    # mv instead of cp: no 45 MB copy
    for b in tailscaled tailscale; do
      $SUDO mv -f "${TS_BIN_DIR}/${b}" "${TS_BIN_DIR}/${b}.bak" 2>/dev/null || true
    done
  fi

  echo "[>] installing ${LATEST}"
  if ! install_ts "$LATEST" "$TS_BIN_DIR"; then
    echo "[x] install failed" >&2
    [ "$ACTION" = "update" ] && restore_backup
    exit 1
  fi

  if ! "${TS_BIN_DIR}/tailscaled" --version >/dev/null 2>&1; then
    echo "[x] new binary won't execute" >&2
    file "${TS_BIN_DIR}/tailscaled" >&2 || true
    mount | grep "$TS_BIN_DIR" >&2 || echo "(no tmpfs mount)" >&2
    [ "$ACTION" = "update" ] && restore_backup
    exit 1
  fi

  $SUDO rm -f "${TS_BIN_DIR}/tailscaled.bak" "${TS_BIN_DIR}/tailscale.bak"
  echo "[+] binary ready"
else
  echo "[+] binary already correct"
fi

# ---------- state dirs ----------
$SUDO mkdir -p "$TS_STATE_DIR" /run/tailscale
$SUDO chmod 700 "$TS_STATE_DIR"
$SUDO chmod 755 /run/tailscale

# ---------- systemd unit (rewritten only if content differs) ----------
WANT_UNIT=$(cat <<UNIT
[Unit]
Description=Tailscale node agent
Wants=network-pre.target
After=network-pre.target
Before=network.target

[Service]
Type=notify
ExecStartPre=${TS_BIN_DIR}/tailscaled --cleanup
ExecStart=${TS_BIN_DIR}/tailscaled --state=${TS_STATE_DIR}/tailscaled.state --socket=${TS_SOCKET} --port=41641
ExecStopPost=${TS_BIN_DIR}/tailscaled --cleanup
Restart=on-failure
RestartSec=5
RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0750
CacheDirectory=tailscale
CacheDirectoryMode=0750
# Keep tailscaled from starving the VM
Nice=10
CPUWeight=50
CPUQuota=20%
IOWeight=10
CPUSchedulingPolicy=batch
MemoryHigh=48M
MemoryMax=80M
Environment=GOGC=40
Environment=GOMEMLIMIT=40MiB
Environment=TS_NO_LOGS_NO_SUPPORT=true

[Install]
WantedBy=multi-user.target
UNIT
)

UNIT_CHANGED=0
if ! printf '%s\n' "$WANT_UNIT" | cmp -s - "$TS_UNIT" 2>/dev/null; then
  echo "[>] writing ${TS_UNIT}"
  printf '%s\n' "$WANT_UNIT" | $SUDO tee "$TS_UNIT" >/dev/null
  $SUDO systemctl daemon-reload
  UNIT_CHANGED=1
else
  echo "[+] systemd unit already correct"
fi

$SUDO systemctl enable tailscaled.service >/dev/null 2>&1

# ---------- service ----------
if [ "$ACTION" != "none" ] || [ "$UNIT_CHANGED" = "1" ] || ! $SUDO systemctl is-active --quiet tailscaled.service; then
  echo "[>] starting tailscaled"
  $SUDO systemctl restart tailscaled.service   # Type=notify: returns once ready
  for _ in $(seq 1 30); do [ -S "$TS_SOCKET" ] && break; sleep 0.5; done
fi

if ! $SUDO systemctl is-active --quiet tailscaled.service; then
  echo "[x] tailscaled not running" >&2
  $SUDO journalctl -u tailscaled.service -n 30 --no-pager >&2 || true
  exit 1
fi
echo "[+] tailscaled running"

# ---------- auth ----------
TS="${TS_BIN_DIR}/tailscale"
TS_IP=$($SUDO "$TS" --socket="$TS_SOCKET" ip -4 2>/dev/null | head -1 || true)
if [ -n "$TS_IP" ]; then
  echo "[+] already authenticated: ${TS_IP}"
elif [ -z "$TS_AUTHKEY" ]; then
  echo "[!] not authenticated and TS_AUTHKEY not set" >&2
else
  echo "[>] authenticating"
  # TS_EXTRA_ARGS is intentionally word-split (e.g. "--netfilter-mode=off")
  # shellcheck disable=SC2086
  $SUDO "$TS" --socket="$TS_SOCKET" up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$TS_HOSTNAME" \
    --advertise-tags=tag:home \
    --accept-dns=true \
    --accept-routes=false \
    ${TS_EXTRA_ARGS:-}

  TS_IP=$($SUDO "$TS" --socket="$TS_SOCKET" ip -4 2>/dev/null | head -1 || true)
  if [ -z "$TS_IP" ]; then
    echo "[x] authentication failed" >&2
    $SUDO "$TS" --socket="$TS_SOCKET" status >&2 || true
    exit 1
  fi
  echo "[+] authenticated: ${TS_IP}"
fi

# ---------- verification ----------
# Fails the script (exit 1) if Tailscale is not healthy.
# Optional: TS_PING_PEER=<tailscale-ip-or-name> also pings a peer end to end.
echo "[>] verifying tailscale health"
FAIL=0
WARN=0
pass() { echo "[✓] $*"; }
bad()  { echo "[x] $*" >&2; FAIL=1; }
warn() { echo "[!] $*" >&2; WARN=1; }

backend_state() {
  $SUDO "$TS" --socket="$TS_SOCKET" status --json 2>/dev/null | tr -d '\n' \
    | grep -oE '"BackendState"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
    | sed -E 's/.*"([^"]+)"$/\1/' || true
}

# 1. Wait (up to ~60s) for the backend to reach Running
STATE=""
for _ in $(seq 1 30); do
  STATE=$(backend_state)
  [ "$STATE" = "Running" ] && break
  sleep 2
done

# 2. Service active
if $SUDO systemctl is-active --quiet tailscaled.service; then
  pass "tailscaled.service is active"
else
  bad "tailscaled.service is not active"
fi

# 3. No crash/restart loop
NR=$($SUDO systemctl show tailscaled.service -p NRestarts --value 2>/dev/null || echo 0)
if [[ "${NR:-0}" =~ ^[0-9]+$ ]] && [ "${NR:-0}" -gt 0 ]; then
  warn "tailscaled auto-restarted ${NR} time(s); check: journalctl -u tailscaled (possible MemoryMax OOM)"
else
  pass "no unexpected restarts"
fi

# 4. Backend state
if [ "$STATE" = "Running" ]; then
  pass "backend state: Running"
else
  bad "backend state: ${STATE:-unknown} (expected Running; NeedsLogin means auth key missing/invalid/expired)"
fi

# 5. Tailnet IPv4 assigned
TS_IP=$($SUDO "$TS" --socket="$TS_SOCKET" ip -4 2>/dev/null | head -1 || true)
if [ -n "$TS_IP" ]; then
  pass "tailnet IPv4: ${TS_IP}"
else
  bad "no tailnet IPv4 address assigned"
fi

# 6. Kernel interface up
if ip link show tailscale0 2>/dev/null | grep -qE '<[^>]*\bUP\b'; then
  pass "tailscale0 interface is UP"
else
  bad "tailscale0 interface missing or down (is /dev/net/tun available?)"
fi

# 7. Tailscale's own health warnings (DNS, control plane, clock, etc.)
HEALTH=$($SUDO "$TS" --socket="$TS_SOCKET" status --json 2>/dev/null | tr -d '\n ' \
  | grep -oE '"Health":(\[[^]]*\]|null)' | head -1 || true)
case "$HEALTH" in
  ""|'"Health":[]'|'"Health":null') pass "no health warnings reported" ;;
  *) warn "tailscale health warnings: ${HEALTH#\"Health\":}" ;;
esac

# 8. Resource limits actually applied
MEMMAX=$($SUDO systemctl show tailscaled.service -p MemoryMax --value 2>/dev/null || true)
MEMCUR=$($SUDO systemctl show tailscaled.service -p MemoryCurrent --value 2>/dev/null || true)
if [ -n "$MEMMAX" ] && [ "$MEMMAX" != "infinity" ]; then
  if [[ "$MEMCUR" =~ ^[0-9]+$ ]]; then
    pass "memory limit active ($((MEMMAX / 1048576)) MB max, using $((MEMCUR / 1048576)) MB)"
  else
    pass "memory limit active ($((MEMMAX / 1048576)) MB max)"
  fi
else
  warn "MemoryMax not applied (cgroup memory controller unavailable?)"
fi

# 9. Optional end-to-end peer ping
if [ -n "${TS_PING_PEER:-}" ]; then
  if $SUDO "$TS" --socket="$TS_SOCKET" ping -c 2 --timeout 5s "$TS_PING_PEER" >/dev/null 2>&1; then
    pass "ping to ${TS_PING_PEER} succeeded"
  else
    bad "ping to ${TS_PING_PEER} failed"
  fi
fi

if [ "$FAIL" -ne 0 ]; then
  echo "[x] tailscale is NOT healthy; diagnostics follow" >&2
  $SUDO "$TS" --socket="$TS_SOCKET" status >&2 || true
  $SUDO journalctl -u tailscaled.service -n 40 --no-pager >&2 || true
  exit 1
fi
if [ "$WARN" -ne 0 ]; then
  echo "[!] tailscale is running, with warnings above"
else
  echo "[+] tailscale verified healthy"
fi

# ---------- summary ----------
echo "[>] summary"
echo "[*] action: ${ACTION}"
echo "[*] version: $(installed_version)"
if ip link show tailscale0 >/dev/null 2>&1; then
  echo "[*] interface: tailscale0 present"
else
  echo "[*] interface: missing" >&2
fi
echo "[+] upsert-tailscale done"
exit 0

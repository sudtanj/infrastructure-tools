#!/usr/bin/env bash
#
# optimize-vm.sh — Tune a GCP free-tier VM (e2-micro: 2 shared vCPU, 1 GB RAM)
# for running Docker + Tailscale without resource exhaustion.
#
# What it does:
#   1. Memory   : zram + disk swapfile, tuned VM sysctls, earlyoom, THP=madvise
#   2. Network  : BBR + fq, socket buffers, UDP GRO forwarding for Tailscale
#   3. Docker   : log rotation, MTU 1460 (GCP), live-restore, no userland-proxy,
#                 a capped containers.slice so containers can't starve the host
#   4. Tailscale: Go GC/memory limit, OOM protection, CPU priority
#   5. System   : journald caps, fstrim, weekly docker prune, OOM-protect sshd
#   6. Optional : --aggressive disables unneeded services (snapd, etc.)
#
# Usage:
#   sudo ./optimize-vm.sh [options]
#
# Options:
#   --dry-run       Show what would change, change nothing
#   --aggressive    Also disable snapd, ModemManager, packagekit, etc.
#   --no-restart    Don't restart docker/tailscaled (apply on next restart)
#   --swap-size N   Disk swapfile size in GB (default: 2)
#   --status        Print current resource status and exit
#   --revert        Remove the config files this script created and exit
#   -h, --help      Show this help
#
# Safe to re-run (idempotent). Backups go to /var/backups/optimize-vm/.

set -euo pipefail

# ---------- config ----------
SWAP_GB=2
DRY_RUN=0
AGGRESSIVE=0
NO_RESTART=0
BACKUP_DIR="/var/backups/optimize-vm/$(date +%Y%m%d-%H%M%S)"
MARK="# managed by optimize-vm.sh"

# ---------- helpers ----------
c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_red=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
info() { echo "${c_grn}[+]${c_off} $*"; }
warn() { echo "${c_ylw}[!]${c_off} $*"; }
err()  { echo "${c_red}[x]${c_off} $*" >&2; }
skip() { echo "${c_dim}[-] $*${c_off}"; }

run() {
  if (( DRY_RUN )); then echo "${c_dim}    (dry-run) $*${c_off}"; else "$@"; fi
}

have() { command -v "$1" >/dev/null 2>&1; }
unit_exists() { systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"; }

# write_file <path> <mode>   (content from stdin). Returns 0 if changed, 1 if unchanged.
write_file() {
  local path="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; skip "unchanged: $path"; return 1
  fi
  if (( DRY_RUN )); then
    echo "${c_dim}    (dry-run) would write $path${c_off}"; rm -f "$tmp"; return 0
  fi
  if [[ -f "$path" ]]; then
    mkdir -p "$BACKUP_DIR$(dirname "$path")"; cp -a "$path" "$BACKUP_DIR$path"
  fi
  mkdir -p "$(dirname "$path")"
  install -m "$mode" "$tmp" "$path"; rm -f "$tmp"
  info "wrote $path"
  return 0
}

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------- args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --aggressive) AGGRESSIVE=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --swap-size)  SWAP_GB="${2:?need a number}"; shift ;;
    --status)     ACTION=status ;;
    --revert)     ACTION=revert ;;
    -h|--help)    usage ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
  shift
done
ACTION="${ACTION:-apply}"

if [[ $EUID -ne 0 ]]; then err "Run as root: sudo $0 $*"; exit 1; fi

# ---------- status ----------
show_status() {
  echo "=== Memory ===";   free -h
  echo; echo "=== Swap ===";    swapon --show 2>/dev/null || echo "none"
  echo; echo "=== Load / CPU ==="; uptime; nproc | sed 's/^/vCPUs: /'
  echo; echo "=== Disk ===";    df -h / | tail -n +1
  echo; echo "=== Network ==="
  echo "congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
  echo "qdisc:              $(sysctl -n net.core.default_qdisc)"
  if have docker && systemctl is-active --quiet docker; then
    echo; echo "=== Docker containers ==="
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null || true
  fi
  if have tailscale; then
    echo; echo "=== Tailscale ==="; tailscale status 2>/dev/null | head -n 5 || true
  fi
  echo; echo "=== Top memory consumers ==="
  ps -eo pid,comm,%mem,%cpu --sort=-%mem | head -n 8
}

# ---------- revert ----------
do_revert() {
  warn "Removing files created by optimize-vm.sh (swap/zram packages are left alone)"
  local files=(
    /etc/sysctl.d/99-optimize-vm.conf
    /etc/systemd/journald.conf.d/99-optimize-vm.conf
    /etc/systemd/system/containers.slice
    /etc/systemd/system/docker.service.d/99-optimize-vm.conf
    /etc/systemd/system/tailscaled.service.d/99-optimize-vm.conf
    /etc/systemd/system/ssh.service.d/99-optimize-vm.conf
    /etc/systemd/system/sshd.service.d/99-optimize-vm.conf
    /etc/systemd/system/optimize-vm-tune.service
    /etc/systemd/system/docker-prune.service
    /etc/systemd/system/docker-prune.timer
    /etc/default/earlyoom.optimize-vm
  )
  for f in "${files[@]}"; do [[ -e "$f" ]] && { run rm -f "$f"; info "removed $f"; }; done
  local latest
  latest="$(ls -1d /var/backups/optimize-vm/*/ 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" && -f "${latest}etc/docker/daemon.json" ]]; then
    run cp -a "${latest}etc/docker/daemon.json" /etc/docker/daemon.json
    info "restored /etc/docker/daemon.json from $latest"
  else
    warn "No daemon.json backup found; review /etc/docker/daemon.json manually"
  fi
  run systemctl daemon-reload
  run sysctl --system >/dev/null
  warn "Restart docker/tailscaled to fully revert: systemctl restart docker tailscaled"
  exit 0
}

[[ "$ACTION" == status ]] && { show_status; exit 0; }
[[ "$ACTION" == revert ]] && do_revert

# ---------- preflight ----------
MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
MEM_MB=$(( MEM_KB / 1024 ))
CPUS="$(nproc)"
info "Detected ${MEM_MB} MB RAM, ${CPUS} vCPU"
(( MEM_MB > 4096 )) && warn "This host has more than 4 GB RAM; tuning is designed for e2-micro and may be conservative."
(( DRY_RUN )) && warn "DRY RUN — no changes will be made"

# Detect primary network interface
IFACE="$(ip -o route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
IFACE="${IFACE:-ens4}"
info "Primary interface: $IFACE"

PKGS=()
have jq       || PKGS+=(jq)
have ethtool  || PKGS+=(ethtool)
have earlyoom || PKGS+=(earlyoom)
if have apt-get; then
  dpkg -s zram-tools >/dev/null 2>&1 || PKGS+=(zram-tools)
fi
if (( ${#PKGS[@]} )); then
  info "Installing packages: ${PKGS[*]}"
  if have apt-get; then
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PKGS[@]}" || warn "Some packages failed to install; continuing"
  else
    warn "apt-get not found; install manually: ${PKGS[*]}"
  fi
fi

# =====================================================================
# 1. MEMORY: swapfile + zram
# =====================================================================
info "[1/6] Memory: swap & zram"

# --- zram (compressed RAM swap, high priority) ---
if [[ -f /etc/default/zramswap || -d /etc/default ]] && have apt-get; then
  if write_file /etc/default/zramswap <<EOF
$MARK
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  then
    unit_exists zramswap.service && run systemctl restart zramswap.service || true
  fi
  unit_exists zramswap.service && run systemctl enable zramswap.service >/dev/null 2>&1 || true
fi

# --- disk swapfile (low priority fallback) ---
SWAPFILE=/swapfile
if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
  skip "swapfile already active"
else
  AVAIL_GB=$(df --output=avail -BG / | tail -n1 | tr -dc '0-9')
  if (( AVAIL_GB < SWAP_GB + 5 )); then
    warn "Only ${AVAIL_GB} GB free on /; skipping ${SWAP_GB} GB swapfile"
  else
    info "Creating ${SWAP_GB} GB swapfile"
    if [[ ! -f $SWAPFILE ]]; then
      run fallocate -l "${SWAP_GB}G" "$SWAPFILE" || run dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(( SWAP_GB * 1024 ))
      run chmod 600 "$SWAPFILE"
      run mkswap "$SWAPFILE" >/dev/null
    fi
    run swapon --priority 10 "$SWAPFILE"
    if ! grep -q "^$SWAPFILE" /etc/fstab; then
      (( DRY_RUN )) || { cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"; echo "$SWAPFILE none swap sw,pri=10 0 0 $MARK" >> /etc/fstab; }
      info "added swapfile to /etc/fstab"
    fi
  fi
fi

# --- earlyoom: kill the right thing BEFORE the box freezes ---
if have earlyoom; then
  write_file /etc/default/earlyoom <<EOF
$MARK
# Trigger at <6% free RAM and <10% free swap; never kill sshd/tailscaled/dockerd
EARLYOOM_ARGS="-m 6 -s 10 -r 3600 --avoid '(^|/)(sshd|tailscaled|dockerd|containerd|systemd|google_guest_agent)$' --prefer '(^|/)(chrome|node|java|python3?)$'"
EOF
  run systemctl enable --now earlyoom >/dev/null 2>&1 || true
  run systemctl restart earlyoom >/dev/null 2>&1 || true
fi

# =====================================================================
# 2. KERNEL / NETWORK SYSCTLS
# =====================================================================
info "[2/6] Kernel & network sysctls"

# Conntrack sizing: each entry ~320 B. Keep it small on 1 GB.
CT_MAX=$(( MEM_MB * 64 ))          # 1 GB -> ~65k entries (~20 MB worst case)
(( CT_MAX < 16384 )) && CT_MAX=16384

if write_file /etc/sysctl.d/99-optimize-vm.conf <<EOF
$MARK

# ---- Memory ----
vm.swappiness = 60                 # zram is cheap; let the kernel use it
vm.vfs_cache_pressure = 100
vm.page-cluster = 0                # zram: no read-ahead of swap pages
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.min_free_kbytes = 16384         # keep headroom so sshd/tailscaled can always allocate
vm.overcommit_memory = 1           # needed by Redis/some containers; earlyoom guards OOM
vm.max_map_count = 262144

# ---- Network: congestion control & queueing ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.ip_local_port_range = 10240 65535

# ---- Network: buffers (modest; large buffers eat RAM on 1 GB) ----
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 2048
net.core.rmem_max = 4194304        # Tailscale/WireGuard UDP wants >= ~4 MB
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304

# ---- Forwarding (Docker, and Tailscale exit node / subnet router) ----
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# ---- Conntrack (applied if module loaded) ----
net.netfilter.nf_conntrack_max = $CT_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# ---- Files / inotify ----
fs.file-max = 524288
fs.inotify.max_user_watches = 262144
fs.inotify.max_user_instances = 512
EOF
then
  modprobe tcp_bbr 2>/dev/null || true
  modprobe nf_conntrack 2>/dev/null || true
  echo tcp_bbr | { (( DRY_RUN )) && cat >/dev/null || tee /etc/modules-load.d/bbr.conf >/dev/null; }
  run sysctl --system >/dev/null 2>&1 || warn "Some sysctls were rejected (harmless if a module is missing)"
fi

# Runtime tuning service: THP, ethtool UDP GRO (Tailscale), reapplied at boot
if write_file /etc/systemd/system/optimize-vm-tune.service <<EOF
$MARK
[Unit]
Description=Runtime VM tuning (THP, UDP GRO forwarding for Tailscale)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled || true'
ExecStart=/bin/sh -c 'echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag || true'
ExecStart=/bin/sh -c 'IF=\$(ip -o route get 8.8.8.8 | sed -n "s/.* dev \\([^ ]*\\).*/\\1/p"); ethtool -K "\$IF" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EOF
then run systemctl daemon-reload; fi
run systemctl enable --now optimize-vm-tune.service >/dev/null 2>&1 || true

# =====================================================================
# 3. DOCKER
# =====================================================================
DOCKER_CHANGED=0
if have docker; then
  info "[3/6] Docker"

  # Cap total container memory/CPU so the host (ssh, tailscale) always survives.
  # MemoryHigh = soft throttle, MemoryMax = hard ceiling.
  MEM_HIGH=$(( MEM_MB * 62 / 100 ))
  MEM_MAX=$(( MEM_MB * 72 / 100 ))
  write_file /etc/systemd/system/containers.slice <<EOF && run systemctl daemon-reload || true
$MARK
[Unit]
Description=Slice for all Docker containers (capped to protect the host)

[Slice]
MemoryAccounting=yes
CPUAccounting=yes
IOAccounting=yes
MemoryHigh=${MEM_HIGH}M
MemoryMax=${MEM_MAX}M
CPUWeight=50
IOWeight=50
EOF

  # Only use cgroup-parent if Docker uses the systemd cgroup driver
  CG_DRIVER="$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo unknown)"
  info "Docker cgroup driver: $CG_DRIVER"

  mkdir -p /etc/docker
  [[ -s /etc/docker/daemon.json ]] || echo '{}' > /etc/docker/daemon.json

  DESIRED='{
    "log-driver": "json-file",
    "log-opts": { "max-size": "10m", "max-file": "3", "compress": "true" },
    "live-restore": true,
    "userland-proxy": false,
    "mtu": 1460,
    "max-concurrent-downloads": 2,
    "max-concurrent-uploads": 2,
    "default-ulimits": { "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 65536 } },
    "features": { "containerd-snapshotter": false }
  }'
  if [[ "$CG_DRIVER" == "systemd" ]]; then
    DESIRED="$(jq '. + {"cgroup-parent": "containers.slice"}' <<<"$DESIRED")"
  else
    warn "Docker isn't using the systemd cgroup driver; skipping containers.slice cap"
  fi

  if have jq; then
    # "features" key is only harmful on some versions; drop it to stay safe
    DESIRED="$(jq 'del(.features)' <<<"$DESIRED")"
    MERGED="$(jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$DESIRED"))"
    if write_file /etc/docker/daemon.json <<<"$MERGED"; then DOCKER_CHANGED=1; fi
  else
    warn "jq not available; skipping daemon.json merge"
  fi

  if write_file /etc/systemd/system/docker.service.d/99-optimize-vm.conf <<EOF
$MARK
[Service]
OOMScoreAdjust=-500
LimitNOFILE=1048576
Nice=-2
EOF
  then DOCKER_CHANGED=1; run systemctl daemon-reload; fi

  # Weekly cleanup so the 30 GB disk doesn't fill up
  write_file /etc/systemd/system/docker-prune.service <<EOF && true
$MARK
[Unit]
Description=Prune unused Docker data older than 7 days

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/docker system prune -af --filter "until=168h"
ExecStart=/usr/bin/docker volume prune -f
EOF
  write_file /etc/systemd/system/docker-prune.timer <<EOF && run systemctl daemon-reload || true
$MARK
[Unit]
Description=Weekly Docker prune

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  run systemctl enable --now docker-prune.timer >/dev/null 2>&1 || true

  if (( DOCKER_CHANGED && ! NO_RESTART )); then
    warn "Restarting Docker (live-restore keeps running containers up if already enabled)"
    run systemctl restart docker
  elif (( DOCKER_CHANGED )); then
    warn "Docker config changed; restart later with: sudo systemctl restart docker"
  fi
else
  skip "[3/6] Docker not installed; skipping"
fi

# =====================================================================
# 4. TAILSCALE
# =====================================================================
if unit_exists tailscaled.service || have tailscaled; then
  info "[4/6] Tailscale"
  TS_CHANGED=0
  if write_file /etc/systemd/system/tailscaled.service.d/99-optimize-vm.conf <<EOF
$MARK
[Service]
# Go runtime: collect garbage earlier and cap heap so tailscaled stays small
Environment=GOGC=50
Environment=GOMEMLIMIT=96MiB
# Never let the OOM killer take out your remote access
OOMScoreAdjust=-900
# Give the VPN scheduling priority over containers
CPUWeight=300
Nice=-5
Restart=always
RestartSec=3
EOF
  then TS_CHANGED=1; run systemctl daemon-reload; fi

  if (( TS_CHANGED && ! NO_RESTART )); then
    warn "Restarting tailscaled (your Tailscale SSH session may blip for a few seconds)"
    run systemctl restart tailscaled
  elif (( TS_CHANGED )); then
    warn "Restart later with: sudo systemctl restart tailscaled"
  fi
else
  skip "[4/6] Tailscale not installed; skipping"
fi

# =====================================================================
# 5. SYSTEM HYGIENE
# =====================================================================
info "[5/6] System hygiene"

# Protect SSH from the OOM killer (service is 'ssh' on Debian/Ubuntu, 'sshd' on others)
for svc in ssh sshd; do
  if unit_exists "$svc.service"; then
    write_file "/etc/systemd/system/$svc.service.d/99-optimize-vm.conf" <<EOF && run systemctl daemon-reload || true
$MARK
[Service]
OOMScoreAdjust=-900
EOF
  fi
done

# Cap journald so logs don't eat disk or I/O
write_file /etc/systemd/journald.conf.d/99-optimize-vm.conf <<EOF && run systemctl restart systemd-journald || true
$MARK
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxFileSec=1week
Compress=yes
RateLimitIntervalSec=30s
RateLimitBurst=2000
EOF

# TRIM weekly (free-tier persistent disk is thin-provisioned)
unit_exists fstrim.timer && run systemctl enable --now fstrim.timer >/dev/null 2>&1 || true

# Clean apt caches
have apt-get && { run apt-get autoremove -y -qq || true; run apt-get clean || true; }

# =====================================================================
# 6. OPTIONAL: disable unneeded services
# =====================================================================
if (( AGGRESSIVE )); then
  info "[6/6] Aggressive: disabling unneeded services"
  for svc in snapd.service snapd.socket snapd.seeded.service ModemManager.service \
             multipathd.service multipathd.socket udisks2.service packagekit.service \
             fwupd.service apport.service motd-news.timer lxd-agent.service \
             ubuntu-advantage.service esm-cache.service; do
    if unit_exists "$svc"; then
      run systemctl disable --now "$svc" >/dev/null 2>&1 && info "disabled $svc" || true
    fi
  done
else
  skip "[6/6] Skipping service cleanup (use --aggressive to disable snapd, ModemManager, etc.)"
fi

# ---------- summary ----------
echo
info "Done. Backups of replaced files: ${BACKUP_DIR}"
echo
if (( ! DRY_RUN )); then show_status; fi

cat <<'EOF'

----------------------------------------------------------------------
 Free-tier tips this script can't do for you
----------------------------------------------------------------------
 * ALWAYS set limits on your own containers, e.g. in docker-compose:
       mem_limit: 256m
       cpus: 0.5
       restart: unless-stopped
 * Egress: free tier includes only 1 GB/month outbound (North America).
   Don't run a Tailscale exit node for heavy traffic from this VM.
 * CPU: e2-micro is burstable (~25% sustained). Avoid builds, transcoding,
   and heavy cron jobs on the VM; build images elsewhere and pull them.
 * Prefer small images (alpine, distroless) and avoid running more than
   2-3 small services; check usage anytime:  sudo ./optimize-vm.sh --status
 * Reboot once so every setting is confirmed to survive a restart.
----------------------------------------------------------------------
EOF

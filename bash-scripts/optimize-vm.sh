#!/usr/bin/env bash
#
# optimize-vm.sh — LOW-CPU tuning for a GCP free-tier VM (e2-micro) on Container-Optimized OS
# running Docker + Tailscale.
#
# Goal: use as little CPU as possible and keep the host (ssh, tailscale) responsive.
#
# Usage:
#   sudo bash optimize-vm.sh [options]
#   cat optimize-vm.sh | sudo bash -s -- [options]      # CI-friendly
#
# Options:
#   --diagnose            Find what is eating CPU (steal, iowait, swap, top cgroups). Changes nothing.
#   --status              Resource snapshot
#   --dry-run             Show what would change
#   --no-restart          Don't restart docker/tailscaled after config changes
#   --zram                Enable zram swap (lz4). OFF by default: compression costs CPU
#   --bbr                 Use BBR+fq. OFF by default: cubic is cheaper on CPU
#   --ts-lean             Tailscale: accept-dns=false, webclient=false (breaks MagicDNS on host)
#   --no-logging-agent    Stop COS Cloud Logging agent (fluent-bit). Big CPU saver, lose Cloud Logging
#   --no-updates          Stop COS auto-update engine (saves CPU/IO, but no auto security updates)
#   --cpu-quota PCT       Hard CPU cap for all containers combined, % of one vCPU (default 100)
#   --container-cpus N    Per-container hard cap via `docker update --cpus N` (e.g. 0.4)
#   --swap-size N         Swapfile size in GB (default 2)
#
# COS wipes /etc on reboot. Persist by running this as the startup script:
#   gcloud compute instances add-metadata VM --zone ZONE \
#       --metadata-from-file startup-script=bash-scripts/optimize-vm.sh

set -uo pipefail

SWAP_GB=2; DRY_RUN=0; NO_RESTART=0; ACTION=apply
USE_ZRAM=0; USE_BBR=0; TS_LEAN=0; NO_LOGGING=0; NO_UPDATES=0
CPU_QUOTA=100; CONTAINER_CPUS=""
STATE_DIR=/var/lib/optimize-vm
MARK="# managed by optimize-vm.sh"

# ---------- self-elevate (works from a file AND when piped: `bash -s < optimize-vm.sh`) ----------
# This block must stay the FIRST command: when piped, bash has read only up to here, so
# `cat` below captures the rest of the script, which is then re-run under sudo.
if [[ $EUID -ne 0 ]]; then
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    exec sudo -n -E bash "${BASH_SOURCE[0]}" "$@"
  else
    _t="$(mktemp /tmp/optimize-vm.XXXXXX)" && cat > "$_t" && exec sudo -n -E bash "$_t" "$@"
    echo "[x] Could not elevate with sudo (is passwordless sudo available for this user?)" >&2; exit 1
  fi
fi
# Clean up the temp copy created above (we are root and running from it)
[[ "${BASH_SOURCE[0]:-}" == /tmp/optimize-vm.* ]] && rm -f "${BASH_SOURCE[0]}"

c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_red=$'\e[31m'; c_dim=$'\e[2m'; c_off=$'\e[0m'
info() { echo "${c_grn}[+]${c_off} $*"; }
warn() { echo "${c_ylw}[!]${c_off} $*"; }
bad()  { echo "${c_red}[x]${c_off} $*"; }
skip() { echo "${c_dim}[-] $*${c_off}"; }
have() { command -v "$1" >/dev/null 2>&1; }
run()  { if (( DRY_RUN )); then echo "${c_dim}    (dry-run) $*${c_off}"; else "$@"; fi; }
unit_exists() { systemctl list-unit-files "$1" 2>/dev/null | grep -q "^$1"; }

write_file() {   # write_file <path> [mode] < content ; returns 0 if changed, 1 if same
  local path="$1" mode="${2:-0644}" tmp; tmp="$(mktemp)"; cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; skip "unchanged: $path"; return 1; fi
  if (( DRY_RUN )); then echo "${c_dim}    (dry-run) would write $path${c_off}"; rm -f "$tmp"; return 0; fi
  if [[ -f "$path" ]]; then
    mkdir -p "$STATE_DIR/backup$(dirname "$path")"
    [[ -e "$STATE_DIR/backup$path" ]] || cp -a "$path" "$STATE_DIR/backup$path"
  fi
  mkdir -p "$(dirname "$path")"; install -m "$mode" "$tmp" "$path"; rm -f "$tmp"
  info "wrote $path"; return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --diagnose) ACTION=diagnose ;;   --status) ACTION=status ;;
    --dry-run) DRY_RUN=1 ;;          --no-restart) NO_RESTART=1 ;;
    --zram) USE_ZRAM=1 ;;            --bbr) USE_BBR=1 ;;
    --ts-lean) TS_LEAN=1 ;;          --no-logging-agent) NO_LOGGING=1 ;;
    --no-updates) NO_UPDATES=1 ;;
    --cpu-quota) CPU_QUOTA="${2:?}"; shift ;;
    --container-cpus) CONTAINER_CPUS="${2:?}"; shift ;;
    --swap-size) SWAP_GB="${2:?}"; shift ;;
    -h|--help) sed -n '2,32p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac; shift
done

TS_CTR=""
if have docker; then
  TS_CTR="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk 'tolower($0) ~ /tailscale/ {print $1; exit}')"
fi
ts_cmd() { if have tailscale; then tailscale "$@"; elif [[ -n "$TS_CTR" ]]; then docker exec "$TS_CTR" tailscale "$@"; else return 1; fi; }

# =====================================================================
# DIAGNOSE
# =====================================================================
do_diagnose() {
  echo "=== Sampling CPU for 5s (vmstat) ==="
  vmstat 1 6 | tee /tmp/vmstat.$$ | tail -n 7
  read -r us sy id wa st si so < <(tail -n 5 /tmp/vmstat.$$ | awk '{us+=$13;sy+=$14;id+=$15;wa+=$16;st+=$17;si+=$7;so+=$8} END{printf "%d %d %d %d %d %d %d",us/NR,sy/NR,id/NR,wa/NR,st/NR,si/NR,so/NR}')
  rm -f /tmp/vmstat.$$
  echo; echo "avg: user=${us}% sys=${sy}% idle=${id}% iowait=${wa}% steal=${st}% swap-in=${si} swap-out=${so}"
  echo; echo "=== Top processes by CPU ==="; ps -eo pid,ni,%cpu,%mem,comm --sort=-%cpu | head -n 9
  echo; echo "=== Top cgroups (systemd-cgtop) ==="
  systemd-cgtop -b -n 2 -d 2 --depth=3 2>/dev/null | tail -n 14 || true
  echo; echo "=== CPU pressure (PSI) ==="; cat /proc/pressure/cpu 2>/dev/null || echo n/a
  if have docker; then echo; echo "=== Containers ==="; docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null; fi
  if ts_cmd status >/dev/null 2>&1; then
    echo; echo "=== Tailscale peers (relay = DERP = more CPU) ==="; ts_cmd status 2>/dev/null | head -n 12
  fi
  echo; echo "=== Verdict ==="
  (( st >= 15 )) && bad "STEAL ${st}%: GCP is throttling your shared-core VM (e2-micro sustains only ~25% of a vCPU). No software tweak fixes this: cut workload or move to a bigger machine."
  (( wa >= 20 )) && bad "IOWAIT ${wa}%: disk bound, usually swap thrashing or heavy logging."
  (( si + so > 100 )) && bad "Swapping heavily (si=$si so=$so): RAM is too small for your containers. Reduce memory use; swap thrash burns CPU via kswapd."
  (( us + sy >= 70 && st < 15 )) && warn "Real CPU use is high: check the top process above (look at containers and healthchecks)."
  (( st < 15 && wa < 20 && us + sy < 70 )) && info "No obvious problem in this sample. Re-run when CPU spikes."
}
[[ $ACTION == diagnose ]] && { do_diagnose; exit 0; }

show_status() {
  free -m; echo; swapon --show 2>/dev/null || echo "no swap"; echo; uptime
  echo "cc=$(sysctl -n net.ipv4.tcp_congestion_control) qdisc=$(sysctl -n net.core.default_qdisc) swappiness=$(sysctl -n vm.swappiness)"
  echo; ps -eo pid,comm,%cpu,%mem --sort=-%cpu | head -n 8
}
[[ $ACTION == status ]] && { show_status; exit 0; }

# ---------- preflight ----------
MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
. /etc/os-release 2>/dev/null || true
info "OS: ${PRETTY_NAME:-unknown} | RAM: ${MEM_MB} MB | vCPU: $(nproc)"
(( DRY_RUN )) && warn "DRY RUN — nothing will be changed"
mkdir -p "$STATE_DIR"

# =====================================================================
# 1. MEMORY (swap thrash = CPU burn, so keep swapping rare)
# =====================================================================
info "[1/6] Memory"
if (( USE_ZRAM )); then
  if swapon --show=NAME --noheadings | grep -q zram; then skip "zram already active"
  elif modprobe zram 2>/dev/null && [[ -e /sys/block/zram0 ]]; then
    run sh -c 'echo 1 > /sys/block/zram0/reset' 2>/dev/null
    run sh -c 'echo lz4 > /sys/block/zram0/comp_algorithm' 2>/dev/null
    run sh -c "echo $((MEM_MB/2))M > /sys/block/zram0/disksize"
    run mkswap /dev/zram0 >/dev/null; run swapon -p 100 /dev/zram0; info "zram (lz4) enabled"
  else warn "zram unsupported by kernel"; fi
else
  # Previous version enabled zstd zram; remove it (compression costs CPU)
  if swapon --show=NAME --noheadings | grep -q zram; then
    info "Disabling zram from earlier run"
    run swapoff /dev/zram0 || warn "could not swapoff zram (not enough free RAM); it clears on reboot"
    run sh -c 'echo 1 > /sys/block/zram0/reset' 2>/dev/null
  fi
fi

SWAPFILE=/var/swapfile
if swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then skip "swapfile active"
else
  AVAIL_GB=$(df --output=avail -BG /var | tail -n1 | tr -dc '0-9')
  if (( AVAIL_GB < SWAP_GB + 5 )); then warn "Low disk (${AVAIL_GB} GB); skipping swapfile"
  else
    if [[ ! -f $SWAPFILE ]]; then
      run fallocate -l "${SWAP_GB}G" "$SWAPFILE" || run dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_GB*1024))
      run chmod 600 "$SWAPFILE"; run mkswap "$SWAPFILE" >/dev/null
    fi
    run swapon -p 10 "$SWAPFILE" && info "swapfile on (safety net only)"
  fi
fi
run sh -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled' 2>/dev/null
run sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag' 2>/dev/null
run sh -c 'echo 0 > /sys/kernel/mm/ksm/run' 2>/dev/null

# =====================================================================
# 2. SYSCTLS tuned for low CPU
# =====================================================================
info "[2/6] Sysctls"
if (( USE_BBR )) && modprobe tcp_bbr 2>/dev/null && grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  NET_CC=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr'
else
  NET_CC=$'net.core.default_qdisc = fq_codel\nnet.ipv4.tcp_congestion_control = cubic'
fi
modprobe nf_conntrack 2>/dev/null
CT_MAX=$(( MEM_MB * 64 )); (( CT_MAX < 16384 )) && CT_MAX=16384

write_file /etc/sysctl.d/99-optimize-vm.conf <<EOF >/dev/null
$MARK
# --- fewer background wakeups / less kernel housekeeping ---
kernel.nmi_watchdog = 0
kernel.numa_balancing = 0
vm.stat_interval = 10
vm.compaction_proactiveness = 0
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
# --- memory: avoid swap churn ---
vm.swappiness = 10
vm.vfs_cache_pressure = 100
vm.page-cluster = 0
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
vm.min_free_kbytes = 16384
vm.overcommit_memory = 1
vm.max_map_count = 262144
# --- network ---
$NET_CC
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 1000
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.netfilter.nf_conntrack_max = $CT_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
fs.inotify.max_user_watches = 262144
fs.inotify.max_user_instances = 512
EOF
run sysctl -p /etc/sysctl.d/99-optimize-vm.conf >/dev/null 2>&1 || true

# =====================================================================
# 3. DOCKER
# =====================================================================
DOCKER_CHANGED=0
if have docker && unit_exists docker.service; then
  info "[3/6] Docker"
  MEM_HIGH=$(( MEM_MB * 62 / 100 )); MEM_MAX=$(( MEM_MB * 72 / 100 ))
  write_file /etc/systemd/system/containers.slice <<EOF >/dev/null && run systemctl daemon-reload
$MARK
[Unit]
Description=Cap for all Docker containers (protects host: sshd, tailscale)
[Slice]
MemoryAccounting=yes
CPUAccounting=yes
MemoryHigh=${MEM_HIGH}M
MemoryMax=${MEM_MAX}M
CPUQuota=${CPU_QUOTA}%
CPUWeight=30
IOWeight=30
EOF

  CG_DRIVER="$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo unknown)"
  mkdir -p /etc/docker; [[ -s /etc/docker/daemon.json ]] || echo '{}' > /etc/docker/daemon.json
  if have jq; then
    DESIRED='{"log-driver":"local","log-opts":{"max-size":"10m","max-file":"3"},"live-restore":true,"userland-proxy":false,"mtu":1460,"max-concurrent-downloads":1,"max-concurrent-uploads":1}'
    [[ "$CG_DRIVER" == systemd ]] && DESIRED="$(jq '. + {"cgroup-parent":"containers.slice"}' <<<"$DESIRED")"
    MERGED="$(jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$DESIRED"))"
  else
    CGP=""; [[ "$CG_DRIVER" == systemd ]] && CGP=',"cgroup-parent":"containers.slice"'
    MERGED="{\"live-restore\":true,\"storage-driver\":\"overlay2\",\"mtu\":1460,\"log-driver\":\"local\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"},\"userland-proxy\":false,\"max-concurrent-downloads\":1,\"max-concurrent-uploads\":1${CGP}}"
  fi
  write_file /etc/docker/daemon.json <<<"$MERGED" >/dev/null && DOCKER_CHANGED=1
  [[ "$CG_DRIVER" != systemd ]] && warn "cgroup driver is '$CG_DRIVER': containers.slice cap unused; per-container limits below still apply"

  write_file /etc/systemd/system/docker.service.d/99-optimize-vm.conf <<EOF >/dev/null && { DOCKER_CHANGED=1; run systemctl daemon-reload; }
$MARK
[Service]
OOMScoreAdjust=-500
EOF

  # Weekly prune at idle priority
  write_file /etc/systemd/system/docker-prune.service <<EOF >/dev/null
$MARK
[Unit]
Description=Prune unused Docker data older than 7 days
[Service]
Type=oneshot
Nice=19
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
ExecStart=/usr/bin/docker system prune -af --filter until=168h
EOF
  write_file /etc/systemd/system/docker-prune.timer <<EOF >/dev/null
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
  run systemctl daemon-reload; run systemctl enable --now docker-prune.timer >/dev/null 2>&1

  if (( DOCKER_CHANGED && ! NO_RESTART )); then warn "Restarting Docker (live-restore keeps containers up)"; run systemctl restart docker
  elif (( DOCKER_CHANGED )); then warn "Docker config changed: sudo systemctl restart docker"; fi

  # Per-container CPU weights/caps (works regardless of cgroup driver)
  for id in $(docker ps -q 2>/dev/null); do
    name="$(docker inspect -f '{{.Name}}' "$id" | tr -d /)"
    if [[ "$name" == "$TS_CTR" && -n "$TS_CTR" ]]; then
      run docker update --cpu-shares 2048 --memory 128m --memory-swap 256m "$id" >/dev/null
    else
      if [[ -n "$CONTAINER_CPUS" ]]; then run docker update --cpu-shares 256 --cpus "$CONTAINER_CPUS" "$id" >/dev/null
      else run docker update --cpu-shares 256 "$id" >/dev/null; fi
    fi
  done
  info "Applied CPU weights to running containers (docker update isn't saved on recreate; set cpus: in compose)"
else
  skip "[3/6] Docker not found"
fi

# =====================================================================
# 4. TAILSCALE
# =====================================================================
info "[4/6] Tailscale"
if unit_exists tailscaled.service; then
  if write_file /etc/systemd/system/tailscaled.service.d/99-optimize-vm.conf <<EOF >/dev/null
$MARK
[Service]
# Default GC pace (GOGC=100) = less GC CPU; only tighten GC near the soft limit
Environment=GOMEMLIMIT=128MiB
# One OS thread pool: less context switching on a shared core
Environment=GOMAXPROCS=1
Environment=TS_NO_LOGS_NO_SUPPORT=true
OOMScoreAdjust=-900
CPUWeight=200
Restart=always
RestartSec=10
EOF
  then run systemctl daemon-reload; (( NO_RESTART )) || run systemctl restart tailscaled; fi
elif [[ -n "$TS_CTR" ]]; then
  warn "Tailscale runs in container '$TS_CTR'. For lowest CPU, recreate it with:"
  echo "      -e GOMAXPROCS=1 -e GOMEMLIMIT=128MiB -e TS_NO_LOGS_NO_SUPPORT=true --oom-score-adj=-900 --cpu-shares 2048"
else skip "Tailscale not found"; fi

if (( TS_LEAN )); then
  info "Tailscale lean mode"
  run ts_cmd set --accept-dns=false --webclient=false || warn "tailscale set failed"
fi
if ts_cmd status 2>/dev/null | grep -q relay; then
  warn "Some Tailscale peers use DERP relay (more CPU+latency). Allow UDP 41641 in the GCP firewall for direct connections."
fi

# =====================================================================
# 5. COS BACKGROUND AGENTS
# =====================================================================
info "[5/6] Background services"
stop_unit() { unit_exists "$1" && { run systemctl stop "$1" 2>/dev/null; run systemctl mask --runtime "$1" >/dev/null 2>&1; info "stopped $1"; }; }
for u in node-problem-detector.service crash-reporter.service crash-sender.service kdump.service; do stop_unit "$u"; done
(( NO_LOGGING )) && for u in fluent-bit.service google-cloud-ops-agent.service; do stop_unit "$u"; done
(( NO_UPDATES )) && for u in update-engine.service update_engine.service; do stop_unit "$u"; done
(( NO_LOGGING )) || { unit_exists fluent-bit.service && warn "fluent-bit (COS Cloud Logging agent) is running and is a common CPU hog; add --no-logging-agent to stop it"; }

# Deprioritize what remains so tailscale/sshd always win
for u in fluent-bit.service update-engine.service google-guest-agent.service google-osconfig-agent.service; do
  unit_exists "$u" && write_file "/etc/systemd/system/${u}.d/99-optimize-vm.conf" <<EOF >/dev/null
$MARK
[Service]
Nice=15
CPUWeight=10
CPUSchedulingPolicy=batch
EOF
done
for svc in ssh sshd; do
  unit_exists "$svc.service" && write_file "/etc/systemd/system/$svc.service.d/99-optimize-vm.conf" <<EOF >/dev/null
$MARK
[Service]
OOMScoreAdjust=-900
CPUWeight=200
EOF
done

# =====================================================================
# 6. JOURNALD (less logging = less CPU and IO)
# =====================================================================
info "[6/6] journald"
if write_file /etc/systemd/journald.conf.d/99-optimize-vm.conf <<EOF >/dev/null
$MARK
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
MaxFileSec=1week
MaxLevelStore=notice
ForwardToSyslog=no
ForwardToKMsg=no
ForwardToConsole=no
SyncIntervalSec=5m
RateLimitIntervalSec=30s
RateLimitBurst=500
EOF
then run systemctl restart systemd-journald; fi
run systemctl daemon-reload

echo; info "Done."
(( DRY_RUN )) || show_status
cat <<'EOF'

----------------------------------------------------------------------
 If CPU is still near 100%, run:   sudo bash optimize-vm.sh --diagnose
   * steal > 15%  => GCP is throttling the shared core (e2-micro ~25% sustained). Not fixable in software.
   * high iowait / swap => RAM too small; trim containers.
   * a container on top => set cpus: / mem_limit: in compose, loosen healthcheck intervals
     (e.g. interval: 60s), and avoid builds/cron on the VM.
 Persist across reboot (COS wipes /etc):
   gcloud compute instances add-metadata VM --zone ZONE \
     --metadata-from-file startup-script=bash-scripts/optimize-vm.sh
 CI step:  gcloud compute ssh VM --zone ZONE --command "sudo bash -s" < bash-scripts/optimize-vm.sh
----------------------------------------------------------------------
EOF

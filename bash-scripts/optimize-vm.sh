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
#   --nat64               Add NAT64 + DNS64 so IPv6-only workloads can reach IPv4-only sites
#   --nat64-mode MODE     auto (default) | public | local
#                           public = DNS64 resolvers + a public NAT64 gateway (zero local CPU; for IPv6-only VMs)
#                           local  = tayga (NAT64) + unbound (DNS64) in one small container (needs IPv4 egress);
#                                    serves IPv6-only Docker networks and Tailscale peers
#   --dns64-servers LIST  Space-separated DNS64 resolvers for public mode
#   --force-nat64         Allow public mode even if this VM has an external IPv4 address (not recommended)
#   --nat64-off           Remove NAT64/DNS64 config and container, then exit
#
# COS wipes /etc on reboot. Persist by running this as the startup script:
#   gcloud compute instances add-metadata VM --zone ZONE \
#       --metadata-from-file startup-script=bash-scripts/optimize-vm.sh

set -uo pipefail

SWAP_GB=2; DRY_RUN=0; NO_RESTART=0; ACTION=apply
USE_ZRAM=0; USE_BBR=0; TS_LEAN=0; NO_LOGGING=0; NO_UPDATES=0
CPU_QUOTA=100; CONTAINER_CPUS=""
NAT64=0; NAT64_MODE=auto; FORCE_NAT64=0; NAT64_ACTIVE=""; DOCKER_V6=0
DNS64_SERVERS="2a00:1098:2c::1 2a00:1098:2b::1 2a01:4f8:c2c:123f::1"
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
    --nat64) NAT64=1 ;;
    --nat64-mode) NAT64=1; NAT64_MODE="${2:?}"; shift ;;
    --dns64-servers) DNS64_SERVERS="${2:?}"; shift ;;
    --force-nat64) FORCE_NAT64=1 ;;
    --nat64-off) ACTION=nat64off ;;
    --container-cpus) CONTAINER_CPUS="${2:?}"; shift ;;
    --swap-size) SWAP_GB="${2:?}"; shift ;;
    -h|--help) sed -n '2,45p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
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

IFACE="$(ip -o route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
[[ -z "$IFACE" ]] && IFACE="$(ip -o -6 route get 2001:4860:4860::8888 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
IFACE="${IFACE:-ens4}"

has_global_ipv6() { ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; }
has_external_ipv4() {
  have curl || return 1
  curl -fsS -m 3 -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' 2>/dev/null \
    | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# ---------- NAT64 decision (needed early: public mode changes Docker's IPv6 config) ----------
if (( NAT64 )); then
  EXT4=0; has_external_ipv4 && EXT4=1
  mode="$NAT64_MODE"
  if [[ $mode == auto ]]; then
    if (( EXT4 )); then mode=local; elif has_global_ipv6; then mode=public; else mode=none; fi
  fi
  case "$mode" in
    none)   warn "NAT64: no external IPv4 and no global IPv6 on this VM. Enable IPv6 on the subnet first." ;;
    public)
      if ! has_global_ipv6; then warn "NAT64 public mode needs a global IPv6 address; skipping"
      elif (( EXT4 && ! FORCE_NAT64 )); then
        warn "This VM has an external IPv4 address. Public DNS64 would route IPv4-only sites through a third-party gateway"
        warn "instead of directly. Skipping. Use --nat64-mode local, or --force-nat64 to override."
      else NAT64_ACTIVE=public; DOCKER_V6=1; fi ;;
    local)  NAT64_ACTIVE=local ;;
    *)      warn "Unknown --nat64-mode '$mode' (use auto|public|local)" ;;
  esac
  [[ -n "$NAT64_ACTIVE" ]] && info "NAT64 mode: $NAT64_ACTIVE"
fi

# ---------- helper for NAT64 firewall rules ----------
ipt_ensure() {   # ipt_ensure <iptables|ip6tables> <table> <chain> <rule...>  (idempotent insert)
  local bin="$1" tbl="$2" chain="$3"; shift 3
  have "$bin" || return 0
  "$bin" -t "$tbl" -C "$chain" "$@" 2>/dev/null || run "$bin" -t "$tbl" -I "$chain" "$@"
}
ipt_remove() {
  local bin="$1" tbl="$2" chain="$3"; shift 3
  have "$bin" || return 0
  while "$bin" -t "$tbl" -C "$chain" "$@" 2>/dev/null; do run "$bin" -t "$tbl" -D "$chain" "$@"; done
}

# ---------- --nat64-off ----------
if [[ $ACTION == nat64off ]]; then
  info "Removing NAT64/DNS64"
  rm -f /etc/systemd/resolved.conf.d/99-dns64.conf; systemctl restart systemd-resolved 2>/dev/null
  have docker && docker rm -f nat64 >/dev/null 2>&1 && info "removed nat64 container"
  ipt_remove iptables nat POSTROUTING -s 192.168.255.0/24 ! -o nat64 -j MASQUERADE
  for b in iptables ip6tables; do
    ipt_remove $b filter FORWARD -i nat64 -j ACCEPT; ipt_remove $b filter FORWARD -o nat64 -j ACCEPT
    for i in docker0 'br+' tailscale0; do for pr in udp tcp; do ipt_remove $b filter INPUT -i "$i" -p $pr --dport 53 -j ACCEPT; done; done
  done
  info "Done. (Docker IPv6 settings in /etc/docker/daemon.json were left as is.)"; exit 0
fi

# =====================================================================
# 1. MEMORY (swap thrash = CPU burn, so keep swapping rare)
# =====================================================================
info "[1/7] Memory"
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
info "[2/7] Sysctls"
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
# forwarding=1 makes the kernel IGNORE router advertisements unless accept_ra=2 (would drop the IPv6 default route)
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.netfilter.nf_conntrack_max = $CT_MAX
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
fs.inotify.max_user_watches = 262144
fs.inotify.max_user_instances = 512
EOF
run sysctl -p /etc/sysctl.d/99-optimize-vm.conf >/dev/null 2>&1 || true
run sysctl -qw "net.ipv6.conf.${IFACE}.accept_ra=2" 2>/dev/null || true

# =====================================================================
# 3. DOCKER
# =====================================================================
DOCKER_CHANGED=0
if have docker && unit_exists docker.service; then
  info "[3/7] Docker"
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
    (( DOCKER_V6 )) && DESIRED="$(jq '. + {"ipv6":true,"fixed-cidr-v6":"fd00:d0c:64::/64","ip6tables":true,"experimental":true}' <<<"$DESIRED")"
    MERGED="$(jq -s '.[0] * .[1]' /etc/docker/daemon.json <(echo "$DESIRED"))"
  else
    CGP=""; [[ "$CG_DRIVER" == systemd ]] && CGP=',"cgroup-parent":"containers.slice"'
    V6=""; (( DOCKER_V6 )) && V6=',"ipv6":true,"fixed-cidr-v6":"fd00:d0c:64::/64","ip6tables":true,"experimental":true'
    MERGED="{\"live-restore\":true,\"storage-driver\":\"overlay2\",\"mtu\":1460,\"log-driver\":\"local\",\"log-opts\":{\"max-size\":\"10m\",\"max-file\":\"3\"},\"userland-proxy\":false,\"max-concurrent-downloads\":1,\"max-concurrent-uploads\":1${CGP}${V6}}"
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
  skip "[3/7] Docker not found"
fi

# =====================================================================
# 4. TAILSCALE
# =====================================================================
info "[4/7] Tailscale"
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
# 5. NAT64 + DNS64
# =====================================================================
nat64_verify_dns64() {
  have resolvectl || return 1
  resolvectl query -t AAAA ipv4only.arpa 2>&1 | grep -q 'AAAA' && resolvectl query -t A google.com >/dev/null 2>&1
}

nat64_public() {
  local conf=/etc/systemd/resolved.conf.d/99-dns64.conf chg=0
  unit_exists systemd-resolved.service || { warn "systemd-resolved not found; set DNS64 servers manually: $DNS64_SERVERS"; return; }
  if write_file "$conf" <<EOF
$MARK
[Resolve]
DNS=${DNS64_SERVERS}
Domains=~.
DNSSEC=no
EOF
  then chg=1; fi
  (( DRY_RUN )) && return
  (( chg )) && { systemctl restart systemd-resolved; sleep 1; }
  if nat64_verify_dns64; then
    info "DNS64 OK: IPv4-only names now resolve to synthesized IPv6 addresses"
  else
    bad "DNS64 check failed; reverting so DNS keeps working"
    rm -f "$conf"; systemctl restart systemd-resolved
    return
  fi
  if have curl; then
    code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://ipv4.google.com 2>/dev/null || true)"
    if [[ "$code" =~ ^[23] ]]; then info "NAT64 OK: reached an IPv4-only site over IPv6 (HTTP $code)"
    else warn "Could not reach an IPv4-only site via NAT64 (got '${code:-no response}'). The public gateway may be down; try --dns64-servers."; fi
  fi
}

nat64_local() {
  have docker || { warn "Docker is required for local NAT64"; return; }
  local dir="$STATE_DIR/nat64" ips=() dev a ifaces="" sum cur
  mkdir -p "$dir"
  # Listen on loopback, the Docker bridge and the tailnet addresses (never on the public NIC)
  ips=(127.0.0.1 ::1)
  for dev in docker0 tailscale0; do
    while read -r a; do [[ -n "$a" ]] && ips+=("${a%%/*}"); done < <(ip -o addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}')
  done
  for a in "${ips[@]}"; do ifaces+="  interface: ${a}@53"$'\n'; done

  write_file "$dir/Dockerfile" <<'EOF' >/dev/null
FROM alpine:3.20
RUN apk add --no-cache tayga unbound iproute2
COPY tayga.conf /etc/tayga.conf
COPY unbound.conf /etc/unbound/unbound.conf
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
EOF
  write_file "$dir/tayga.conf" <<'EOF' >/dev/null
tun-device nat64
ipv4-addr 192.168.255.1
ipv6-addr fd64::1
prefix 64:ff9b::/96
dynamic-pool 192.168.255.0/24
data-dir /var/db/tayga
EOF
  write_file "$dir/unbound.conf" <<EOF >/dev/null
server:
  verbosity: 0
  use-syslog: no
  chroot: ""
  pidfile: ""
  ip-freebind: yes
${ifaces}  access-control: 127.0.0.0/8 allow
  access-control: ::1/128 allow
  access-control: 172.16.0.0/12 allow
  access-control: 100.64.0.0/10 allow
  access-control: fd00::/8 allow
  access-control: fd7a:115c:a1e0::/48 allow
  access-control: 0.0.0.0/0 refuse
  access-control: ::/0 refuse
  do-ip4: yes
  do-ip6: yes
  module-config: "dns64 iterator"
  dns64-prefix: 64:ff9b::/96
  num-threads: 1
  msg-cache-size: 4m
  rrset-cache-size: 8m
  cache-min-ttl: 300
  prefetch: no
  hide-identity: yes
  hide-version: yes
forward-zone:
  name: "."
  forward-addr: 2606:4700:4700::1111
  forward-addr: 2001:4860:4860::8888
  forward-addr: 1.1.1.1
  forward-addr: 8.8.8.8
EOF
  write_file "$dir/entrypoint.sh" <<'EOF' >/dev/null
#!/bin/sh
mkdir -p /var/db/tayga
tayga --mktun -c /etc/tayga.conf || exit 1
ip link set nat64 up
ip addr replace 192.168.255.1/32 dev nat64
ip addr replace fd64::1/128 dev nat64
ip route replace 192.168.255.0/24 dev nat64
ip route replace 64:ff9b::/96 dev nat64
tayga -c /etc/tayga.conf -d & TP=$!
unbound -d -c /etc/unbound/unbound.conf & UP=$!
trap 'kill $TP $UP 2>/dev/null; exit 0' TERM INT
# exit if either dies so Docker's restart policy brings both back
while kill -0 $TP 2>/dev/null && kill -0 $UP 2>/dev/null; do sleep 30; done
exit 1
EOF

  if (( DRY_RUN )); then echo "${c_dim}    (dry-run) would build image and run container 'nat64'${c_off}"
  else
    sum="$(cat "$dir"/Dockerfile "$dir"/tayga.conf "$dir"/unbound.conf "$dir"/entrypoint.sh | sha256sum | cut -c1-16)"
    cur="$(docker inspect -f '{{index .Config.Labels "optimize-vm.cfg"}}' nat64 2>/dev/null || true)"
    if [[ "$cur" == "$sum" ]] && [[ -n "$(docker ps -q -f name='^nat64$')" ]]; then
      skip "nat64 container already running with current config"
    else
      info "Building and starting nat64 container (tayga + unbound)"
      if docker build -q -t optimize-vm/nat64 "$dir" >/dev/null; then
        docker rm -f nat64 >/dev/null 2>&1
        docker run -d --name nat64 --restart unless-stopped --network host \
          --cap-add NET_ADMIN --device /dev/net/tun \
          --memory 64m --memory-swap 64m --cpu-shares 512 \
          --label "optimize-vm.cfg=$sum" optimize-vm/nat64 >/dev/null \
          || warn "failed to start nat64 container"
      else warn "image build failed (can Docker reach Docker Hub? with IPv6 only, run --nat64-mode public first)"; fi
    fi
  fi

  # Host plumbing: forward + masquerade the translated IPv4 side, allow DNS from docker/tailnet
  ipt_ensure iptables nat POSTROUTING -s 192.168.255.0/24 ! -o nat64 -j MASQUERADE
  for b in iptables ip6tables; do
    ipt_ensure $b filter FORWARD -i nat64 -j ACCEPT
    ipt_ensure $b filter FORWARD -o nat64 -j ACCEPT
    for i in docker0 'br+' tailscale0; do for pr in udp tcp; do ipt_ensure $b filter INPUT -i "$i" -p $pr --dport 53 -j ACCEPT; done; done
  done
  run sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
}

if [[ -n "$NAT64_ACTIVE" ]]; then
  info "[5/7] NAT64 + DNS64 ($NAT64_ACTIVE)"
  case "$NAT64_ACTIVE" in public) nat64_public ;; local) nat64_local ;; esac
else
  skip "[5/7] NAT64/DNS64 not requested (use --nat64)"
fi

# =====================================================================
# 6. COS BACKGROUND AGENTS
# =====================================================================
info "[6/7] Background services"
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
info "[7/7] journald"
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
case "$NAT64_ACTIVE" in
  public) echo; info "NAT64 (public): this VM resolves via DNS64 and reaches IPv4-only sites through a third-party gateway."
          echo "    Traffic to IPv4-only sites leaves via that gateway; use TLS. Test: curl -6 -I http://ipv4.google.com"
          echo "    New Docker containers get IPv6 (restart/recreate old ones). Managed alternative: Cloud NAT64 + Cloud DNS DNS64 policy." ;;
  local)  echo; info "NAT64 (local): translator 64:ff9b::/96 + DNS64 resolver are running in container 'nat64'."
          echo "    Docker:    docker network create --ipv6 --subnet fd00:64:1::/64 v6net"
          echo "               docker run --network v6net --dns <docker0-IP> ...   (v6-only containers reach IPv4 sites)"
          echo "    Tailscale: tailscale set --advertise-routes=64:ff9b::/96  (approve in admin console), then point"
          echo "               IPv6-only peers' DNS at this node's tailnet IP (port 53)." ;;
esac
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

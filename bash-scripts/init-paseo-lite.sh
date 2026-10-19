#!/bin/bash
# bash-scripts/init-paseo-lite.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Target: GCP free-tier e2-micro (1 GB RAM). One container: paseo-lite
# (Rust Paseo daemon + native Claude Code + native Codex, no Node.js).
# Same secrets as init-paseo-codex.sh: CODEX_*, GH_TOKEN, ANTHROPIC_*, CLAUDE_CODE_*,
# plus optional GH_USERNAME / GH_EMAIL (global git identity).
#
# DNS64_MODE = auto (default) | on | off
#   auto: pass the DNS64 resolvers to the container only when the VM has NO external IPv4
#         (IPv6-only). With an external IPv4, the container uses the host's normal DNS.
#   on:   always pass DNS64 resolvers      off: never pass them
#
# INIT_DEBUG = 1 (default) | 0
#   1: extra "[d]" diagnostic lines (host snapshot, config summary, timings, container state).
#      Secrets are NEVER printed: only set/unset, and all captured output goes through redact().
#   0: quiet, original output only.

set -euo pipefail

INIT_DEBUG="${INIT_DEBUG:-1}"
DOCKER_PREFLIGHT_TIMEOUT="${DOCKER_PREFLIGHT_TIMEOUT:-20}"   # seconds to wait for the docker daemon
PULL_TIMEOUT_SECS="${PULL_TIMEOUT_SECS:-1200}"               # give up on a stuck image pull
PULL_BEAT_SECS="${PULL_BEAT_SECS:-20}"                       # progress line interval while pulling
T_START=$(date +%s)

# ---------- debug helpers ----------
dbg()     { [ "$INIT_DEBUG" = "1" ] && echo "[d] $*" || true; }
since()   { echo "$(( $(date +%s) - $1 ))s"; }
present() { if [ -n "${1:-}" ]; then echo "set"; else echo "unset"; fi; }
url_host() {  # host part only (drops scheme, credentials, path, query) so URLs never leak tokens
  if [ -z "${1:-}" ]; then echo "none"; return; fi
  printf '%s' "$1" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/@]*@)?([^/:?]+).*#\2#'
}

# Bounded docker call for diagnostics, so a wedged daemon can't hang the whole run.
dk() { if command -v timeout >/dev/null 2>&1; then timeout 15 docker "$@"; else docker "$@"; fi; }
# One-line system pressure summary (no addresses): helps tell "slow" from "thrashing".
sys_brief() {
  echo "load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) mem_avail=$(free -m | awk '/^Mem:/{print $7}')MB swap_used=$(free -m | awk '/^Swap:/{print $3}')MB disk_free=$(df -h /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}')"
}

# Masks the literal value of every secret, plus common token shapes, in whatever is piped through.
redact() {
  local t v s
  t=$(cat)
  for v in CODEX_API_KEY GH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN PASEO_PASSWORD; do
    s="${!v:-}"
    if [ -n "$s" ]; then t="${t//"$s"/***}"; fi
  done
  printf '%s\n' "$t" | sed -E 's/(gh[pousr]_|github_pat_|sk-[A-Za-z0-9-]*)[A-Za-z0-9_]{6,}/\1***/g'
}

# On any unexpected failure, say where. (BASH_COMMAND is the unexpanded command text, so no secret values.)
trap 'rc=$?; echo "[x] error at line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR
trap 'rc=$?; dbg "exit code ${rc} after $(since "$T_START")"' EXIT

CODEX_BASE_URL="${CODEX_BASE_URL:-}"
CODEX_API_KEY="${CODEX_API_KEY:-}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_MAX_TOKEN="${CODEX_MAX_TOKEN:-8192}"
# Claude Code reply cap; 8192 cut off long replies ("exceeded the 8192 output token maximum").
CLAUDE_MAX_OUTPUT_TOKENS="${CLAUDE_MAX_OUTPUT_TOKENS:-32000}"
GH_TOKEN="${GH_TOKEN:-}"
# Optional global git identity for agent commits (GitHub Actions secrets).
GH_USERNAME="${GH_USERNAME:-}"
GH_EMAIL="${GH_EMAIL:-}"

# Claude Code auth (optional): OAuth token, API key, or BYOK gateway.
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"

# Fixed at 6768: 6767 is already taken on the host (paseo-codex). With
# --network=host the daemon binds this host port directly.
PASEO_PORT="6768"
PASEO_PASSWORD="${PASEO_PASSWORD:-}"

# --- Resources (host safety first: sshd/tailscale must always stay reachable) ---
# The daemon itself needs a few MB; the cap is for the agent CLIs it runs.
# paseo-lite shares one codex app-server across projects and, with
# PASEO_CLAUDE_MAX_LIVE=auto, runs as many agents at once as the container's
# memory and CPU allow (one on a 1 GB VM), adding workers only while the
# machine stays calm. So the container is sized from the host: everything
# but a reserve for the host itself (sshd, tailscale, docker), never less
# than the 1 GB VM's 640 MB / 0.75 CPU.
# Container swap disabled (memory-swap == memory): a clean OOM-kill of the
# container + auto-restart beats thrashing. Host gets its own swap below.
HOST_MEM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
HOST_CPUS=$(nproc 2>/dev/null || echo 1)
HOST_RESERVE_MB=$(( HOST_MEM_MB / 8 > 384 ? HOST_MEM_MB / 8 : 384 ))
AUTO_MEM_MB=$(( HOST_MEM_MB - HOST_RESERVE_MB > 640 ? HOST_MEM_MB - HOST_RESERVE_MB : 640 ))
if [ "$HOST_CPUS" -gt 2 ]; then AUTO_CPU_LIMIT="$(( HOST_CPUS - 1 ))"; else AUTO_CPU_LIMIT="0.75"; fi
CPU_LIMIT="${CPU_LIMIT:-$AUTO_CPU_LIMIT}"
MEM_MB="${MEM_MB:-$AUTO_MEM_MB}"
# Each agent runs git, rg, shells: room for ~256 processes per 640 MB.
AUTO_PIDS_LIMIT=$(( MEM_MB * 256 / 640 ))
PIDS_LIMIT="${PIDS_LIMIT:-$AUTO_PIDS_LIMIT}"
CLAUDE_MAX_LIVE="${PASEO_CLAUDE_MAX_LIVE:-auto}"
CLAUDE_IDLE_SECS="${PASEO_CLAUDE_IDLE_SECS:-60}"
CODEX_IDLE_SECS="${PASEO_CODEX_IDLE_SECS:-300}"

# Opt-in: share the host's Docker with the agents (PASEO_DOCKER_SOCKET=1), so they
# can run any container on the host. That is root-equivalent on this machine.
PASEO_DOCKER_SOCKET="${PASEO_DOCKER_SOCKET:-0}"
DOCKER_SOCK="${DOCKER_SOCK:-/var/run/docker.sock}"
SOCK_ARGS=()
SOCK_GID=""
if [ "$PASEO_DOCKER_SOCKET" = "1" ]; then
  if [ -S "$DOCKER_SOCK" ]; then
    # The container runs as 1000:1000, so it joins the socket's group instead.
    SOCK_GID=$(stat -c %g "$DOCKER_SOCK")
    SOCK_ARGS=(-v "${DOCKER_SOCK}:/var/run/docker.sock" --group-add "$SOCK_GID")
    case "$(stat -c %a "$DOCKER_SOCK")" in
      *[67]?) echo "[+] host Docker socket shared with the agents (group ${SOCK_GID})" ;;
      *) echo "[!] ${DOCKER_SOCK} is not group-writable ($(stat -c %a "$DOCKER_SOCK")); the agents' docker commands will be refused" ;;
    esac
  else
    echo "[!] PASEO_DOCKER_SOCKET=1 but there is no socket at ${DOCKER_SOCK}; not shared"
  fi
fi

# Bump this whenever the docker run flags change (DNS, limits, etc.) so the
# container is recreated; the hash below only covers values, not the flags.
CONFIG_REV="5"
DNS64_MODE="${DNS64_MODE:-auto}"
DNS1="${DNS1:-2a00:1098:2b::1}"
DNS2="${DNS2:-2a01:4f9:c010:3f02::1}"

IMAGE="sudtanj/paseo-lite:latest"
CONTAINER_NAME="paseo-lite"
HOME_VOLUME="paseo-lite-home"
WORKSPACE_VOLUME="paseo-workspace"

echo "[*] init start"

# ---------- docker preflight: fail fast with a reason instead of hanging ----------
docker_preflight() {
  local t0
  t0=$(date +%s)
  if command -v timeout >/dev/null 2>&1; then
    if ! timeout "$DOCKER_PREFLIGHT_TIMEOUT" docker version -f '{{.Server.Version}}' >/dev/null 2>&1; then
      echo "[x] docker daemon did not respond within ${DOCKER_PREFLIGHT_TIMEOUT}s" >&2
      echo "[x] services: docker=$(systemctl is-active docker.service 2>&1) containerd=$(systemctl is-active containerd.service 2>&1)" >&2
      echo "[x] system: $(sys_brief)" >&2
      echo "[x] last docker journal lines:" >&2
      sudo -n journalctl -u docker.service -n 15 --no-pager -o cat 2>&1 | redact | sed 's/^/    | /' >&2 || true
      echo "[x] last containerd journal lines:" >&2
      sudo -n journalctl -u containerd.service -n 10 --no-pager -o cat 2>&1 | redact | sed 's/^/    | /' >&2 || true
      exit 1
    fi
  fi
  dbg "docker daemon responded in $(since "$t0")"
}
docker_preflight

# ---------- host snapshot (debug only) ----------
host_snapshot() {
  dbg "user: $(id -un) (uid $(id -u)) | host: $(hostname) | kernel: $(uname -r)"
  dbg "time: $(date -u +%FT%TZ) | uptime: $(uptime -p 2>/dev/null || uptime)"
  dbg "cpu: $(nproc) vCPU | load(1/5/15m): $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  dbg "memory: $(free -m | awk '/^Mem:/{printf "total=%sMB used=%sMB avail=%sMB", $2,$3,$7}') | swap: $(free -m | awk '/^Swap:/{printf "total=%sMB used=%sMB", $2,$3}')"
  dbg "disk /var/lib/docker: $(df -h /var/lib/docker 2>/dev/null | awk 'NR==2{printf "size=%s used=%s avail=%s use=%s", $2,$3,$4,$5}')"
  dbg "sudo -n: $(sudo -n true 2>/dev/null && echo yes || echo no) | bash: ${BASH_VERSION}"
  dbg "docker: server=$(dk version -f '{{.Server.Version}}' 2>/dev/null || echo unknown) cgroup=$(dk info -f '{{.CgroupDriver}}/v{{.CgroupVersion}}' 2>/dev/null || echo unknown) storage=$(dk info -f '{{.Driver}}' 2>/dev/null || echo unknown)"
  dbg "docker containers running: $(dk ps -q 2>/dev/null | wc -l) | images: $(dk images -q 2>/dev/null | wc -l)"
  dbg "system: $(sys_brief)"
}
host_snapshot

# ---------- config summary (debug only; never prints secret values) ----------
dbg "config: image=${IMAGE} container=${CONTAINER_NAME} port=${PASEO_PORT} rev=${CONFIG_REV}"
dbg "limits: cpus=${CPU_LIMIT} mem=${MEM_MB}m pids=${PIDS_LIMIT} claude_max_live=${CLAUDE_MAX_LIVE} claude_idle=${CLAUDE_IDLE_SECS}s codex_idle=${CODEX_IDLE_SECS}s"
dbg "secrets: CODEX_API_KEY=$(present "$CODEX_API_KEY") GH_TOKEN=$(present "$GH_TOKEN") ANTHROPIC_API_KEY=$(present "$ANTHROPIC_API_KEY") ANTHROPIC_AUTH_TOKEN=$(present "$ANTHROPIC_AUTH_TOKEN") CLAUDE_CODE_OAUTH_TOKEN=$(present "$CLAUDE_CODE_OAUTH_TOKEN") PASEO_PASSWORD=$(present "$PASEO_PASSWORD")"
dbg "settings: CODEX_BASE_URL host=$(url_host "$CODEX_BASE_URL") CODEX_MODEL=${CODEX_MODEL:-<default>} ANTHROPIC_BASE_URL host=$(url_host "$ANTHROPIC_BASE_URL") ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-<default>} GH_USERNAME=$(present "$GH_USERNAME") GH_EMAIL=$(present "$GH_EMAIL")"

# --- DNS64: only on IPv6-only VMs ---
# DNS64 resolvers (nat64.net) let an IPv6-only host reach IPv4-only services like github.com.
# With an external IPv4 address they are unnecessary and can break resolution, so in "auto"
# mode they are skipped whenever an external IPv4 exists.
MDS="http://169.254.169.254/computeMetadata/v1"   # by IP: works even when DNS is broken

metadata_reachable() {
  curl -sf -m 3 -H 'Metadata-Flavor: Google' "${MDS}/instance/id" >/dev/null 2>&1
}
has_external_ipv4() {
  local v
  v=$(curl -sf -m 3 -H 'Metadata-Flavor: Google' \
        "${MDS}/instance/network-interfaces/0/access-configs/0/external-ip" 2>/dev/null || true)
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
has_global_ipv6() {
  local v
  v=$(ip -6 addr show scope global 2>/dev/null || true)
  [[ "$v" == *inet6* ]]
}

dbg "network: metadata=$(metadata_reachable && echo reachable || echo unreachable) external_ipv4=$(has_external_ipv4 && echo yes || echo no) global_ipv6=$(has_global_ipv6 && echo yes || echo no)"
dbg "host resolver: $(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd' ' - || echo unknown)"

USE_DNS64=0
case "$DNS64_MODE" in
  off) echo "[+] DNS64: disabled (DNS64_MODE=off)" ;;
  on)  USE_DNS64=1; echo "[+] DNS64: forced on (DNS64_MODE=on)" ;;
  auto)
    if ! metadata_reachable; then
      echo "[!] DNS64: cannot read GCE metadata, so IPv6-only can't be detected; not using DNS64 (set DNS64_MODE=on to force)" >&2
    elif has_external_ipv4; then
      echo "[+] DNS64: skipped, VM has an external IPv4 address"
    elif ! has_global_ipv6; then
      echo "[!] DNS64: no external IPv4 and no global IPv6; not using DNS64" >&2
    else
      USE_DNS64=1; echo "[+] DNS64: IPv6-only VM detected, using DNS64 resolvers"
    fi ;;
  *) echo "[x] DNS64_MODE must be auto, on or off (got '${DNS64_MODE}')" >&2; exit 1 ;;
esac

DNS_ARGS=()
DNS_HASH="dns:default"
if [ "$USE_DNS64" = "1" ]; then
  DNS_ARGS=(--dns "$DNS1" --dns "$DNS2")
  DNS_HASH="dns64:${DNS1},${DNS2}"
fi
dbg "dns decision: mode=${DNS64_MODE} use_dns64=${USE_DNS64} container_dns=${DNS_HASH}"

# --- Validate env ---
missing=()
[ -z "$CODEX_API_KEY" ] && missing+=("CODEX_API_KEY")
[ -z "$GH_TOKEN" ]      && missing+=("GH_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[x] missing required env: ${missing[*]}" >&2
  exit 1
fi
dbg "required env present"
[ -z "$PASEO_PASSWORD" ] && echo "[!] PASEO_PASSWORD not set - direct connections on :${PASEO_PORT} are unauthenticated (relay clients still need the pairing key)" >&2

# --- Host protection (idempotent, best-effort, never restarts sshd) ---
# 1) Host swapfile so a memory spike doesn't hang the VM.
if [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then
  echo "[>] creating 1G host swapfile"
  if sudo -n sh -c 'fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile' 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo -n tee -a /etc/fstab >/dev/null
    dbg "host swapfile created and enabled"
  else
    echo "[!] swapfile creation failed (no sudo or no disk space)" >&2
  fi
else
  dbg "host swap already active: $(swapon --show --noheadings 2>/dev/null | awk '{printf "%s(%s) ", $1, $3}')"
fi
sudo -n sysctl -q vm.swappiness=10 2>/dev/null || true
dbg "vm.swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo unknown)"
# 2) Make the kernel OOM-killer avoid sshd/tailscaled/docker (applies on their next restart).
for svc in ssh sshd tailscaled docker; do
  if systemctl cat "$svc" >/dev/null 2>&1; then
    f="/etc/systemd/system/${svc}.service.d/oom.conf"
    if [ ! -f "$f" ]; then
      sudo -n mkdir -p "$(dirname "$f")" 2>/dev/null \
        && printf '[Service]\nOOMScoreAdjust=-900\n' | sudo -n tee "$f" >/dev/null 2>&1 || true
      dbg "oom drop-in created for ${svc}"
    else
      dbg "oom drop-in already present for ${svc}"
    fi
  fi
done
sudo -n systemctl daemon-reload 2>/dev/null || true
sudo -n systemctl enable docker >/dev/null 2>&1 || true

# --- Pull latest image before touching the running container ---
PREV_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo "none")
dbg "pulling ${IMAGE} (local image before pull: ${PREV_ID:0:19})"
T_PULL=$(date +%s)
PULL_LOG=$(mktemp)
# Run the pull in the background so we can print progress and enforce a timeout (a first pull on a
# throttled e2-micro can take minutes and would otherwise look like a hang).
docker pull -q "$IMAGE" >"$PULL_LOG" 2>&1 &
PULL_PID=$!
NEXT_BEAT="$PULL_BEAT_SECS"
while kill -0 "$PULL_PID" 2>/dev/null; do
  el=$(( $(date +%s) - T_PULL ))
  if [ "$el" -ge "$PULL_TIMEOUT_SECS" ]; then
    kill "$PULL_PID" 2>/dev/null || true
    echo "[x] docker pull timed out after ${el}s ($(sys_brief))" >&2
    echo "[x] likely causes: slow/throttled VM (CPU steal or swap thrash), a very large image, or a stalled registry connection" >&2
    rm -f "$PULL_LOG"
    exit 1
  fi
  if [ "$el" -ge "$NEXT_BEAT" ]; then
    echo "[>] still pulling ${IMAGE} (${el}s elapsed)"
    dbg "pull progress: $(sys_brief)"
    NEXT_BEAT=$(( NEXT_BEAT + PULL_BEAT_SECS ))
  fi
  sleep 2
done
if ! wait "$PULL_PID"; then
  echo "[x] docker pull failed - current container left untouched" >&2
  redact < "$PULL_LOG" >&2
  rm -f "$PULL_LOG"
  exit 1
fi
rm -f "$PULL_LOG"
NEW_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo "unknown")
if [ "$PREV_ID" = "$NEW_ID" ]; then IMG_NOTE="unchanged"; else IMG_NOTE="CHANGED"; fi
dbg "pull ok in $(since "$T_PULL"): image ${NEW_ID:0:19} (${IMG_NOTE}) size=$(docker image inspect -f '{{.Size}}' "$IMAGE" 2>/dev/null | awk '{printf "%.0fMB", $1/1048576}')"
[ "$PREV_ID" != "none" ] && [ "$PREV_ID" != "$NEW_ID" ] && docker image prune -f >/dev/null 2>&1 || true

# --- Skip restart if nothing changed ---
CONFIG_HASH=$(printf '%s\n' "$NEW_ID" "$CODEX_BASE_URL" "$CODEX_API_KEY" "$CODEX_MODEL" \
  "$CODEX_MAX_TOKEN" "$CLAUDE_MAX_OUTPUT_TOKENS" "$GH_TOKEN" "$GH_USERNAME" "$GH_EMAIL" "$ANTHROPIC_API_KEY" "$ANTHROPIC_AUTH_TOKEN" \
  "$ANTHROPIC_BASE_URL" "$ANTHROPIC_MODEL" "$CLAUDE_CODE_OAUTH_TOKEN" \
  "$PASEO_PORT" "$PASEO_PASSWORD" "$CPU_LIMIT" "$MEM_MB" "$PIDS_LIMIT" \
  "$CLAUDE_MAX_LIVE" "$CLAUDE_IDLE_SECS" "$CODEX_IDLE_SECS" "$CONFIG_REV" "$DNS_HASH" \
  "$PASEO_DOCKER_SOCKET" "$DOCKER_SOCK" "$SOCK_GID" \
  | sha256sum | cut -d' ' -f1)
CUR_HASH=$(docker inspect -f '{{ index .Config.Labels "init.hash" }}' "$CONTAINER_NAME" 2>/dev/null || echo "")
RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")
EXISTS=$(docker inspect -f '{{.Id}}' "$CONTAINER_NAME" >/dev/null 2>&1 && echo yes || echo no)
CUR_SHORT="${CUR_HASH:0:12}"; CUR_SHORT="${CUR_SHORT:-none}"
dbg "hash: desired=${CONFIG_HASH:0:12} current=${CUR_SHORT} | container exists=${EXISTS} running=${RUNNING}"

if [ "$CUR_HASH" = "$CONFIG_HASH" ] && [ "$RUNNING" = "true" ]; then
  echo "[+] unchanged - container left running"
  dbg "container: $(docker inspect -f 'status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}} oom_killed={{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null)"
  dbg "usage: $(dk stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$CONTAINER_NAME" 2>/dev/null || echo n/a)"
  exit 0
fi

if [ "$EXISTS" = "no" ]; then REASON="container does not exist"
elif [ "$RUNNING" != "true" ]; then REASON="container is not running (status=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown))"
elif [ "$IMG_NOTE" = "CHANGED" ]; then REASON="new image pulled"
else REASON="config/secrets/limits/DNS changed"
fi

# --- Recreate the container ---
echo "[>] replacing $CONTAINER_NAME"
dbg "reason: ${REASON}"
if [ "$EXISTS" = "yes" ]; then
  dbg "old container: $(docker inspect -f 'status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}} exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null)"
fi
# Graceful stop first: SIGTERM lets paseo-lite save agent state and the running
# turn so it resumes after the restart (rm -f alone is SIGKILL with no flush).
T_STOP=$(date +%s)
docker stop -t 30 "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
dbg "old container stopped and removed in $(since "$T_STOP")"
if command -v ss >/dev/null 2>&1 && [ -n "$(ss -Hltn "sport = :${PASEO_PORT}" 2>/dev/null)" ]; then
  echo "[x] port ${PASEO_PORT} is already in use on the host - not starting ${CONTAINER_NAME}" >&2
  dbg "listener on :${PASEO_PORT}: $(ss -Hltnp "sport = :${PASEO_PORT}" 2>/dev/null | head -n 3)"
  exit 1
fi
dbg "port ${PASEO_PORT} is free"
docker volume create "$HOME_VOLUME"      >/dev/null
docker volume create "$WORKSPACE_VOLUME" >/dev/null
dbg "volumes ready: ${HOME_VOLUME}, ${WORKSPACE_VOLUME}"

# Only forward secrets that are actually set.
opt_env=()
opt_names=()
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
         ANTHROPIC_MODEL CLAUDE_CODE_OAUTH_TOKEN PASEO_PASSWORD CODEX_MODEL; do
  if [ -n "${!v:-}" ]; then opt_env+=(-e "$v=${!v}"); opt_names+=("$v"); fi
done
dbg "optional env forwarded to container: ${opt_names[*]:-none}"

# CODEX_BASE_URL is deliberately NOT passed into the container: this script
# writes the complete Codex provider config itself (below), so the image's
# start-time generator must not append a second [model_providers.custom].
#
# apparmor=unconfined is required for bwrap to create user namespaces
# (Codex sandbox). DNS_ARGS: DNS64 resolvers (nat64.net), added ONLY on IPv6-only
# hosts (see the DNS64 block above) so they can reach IPv4-only services like
# github.com; empty when the VM has an external IPv4. Docker applies --dns even
# with --network=host. --restart always: restarts on crash, OOM kill, and
# Docker/VM reboot.
dbg "starting container"
T_RUN=$(date +%s)
if ! run_out=$(docker run -d --name "$CONTAINER_NAME" --restart always \
  --label "init.hash=${CONFIG_HASH}" \
  --stop-timeout 30 \
  --user 1000:1000 \
  --network=host \
  --cpus "$CPU_LIMIT" \
  --cpu-shares 128 \
  --memory "${MEM_MB}m" \
  --memory-reservation "$(( MEM_MB * 80 / 100 ))m" \
  --memory-swap "${MEM_MB}m" \
  --pids-limit "$PIDS_LIMIT" \
  --ulimit nproc=$(( PIDS_LIMIT * 2 )):$(( PIDS_LIMIT * 2 )) \
  --ulimit core=0 \
  --oom-score-adj 500 \
  --log-driver json-file \
  --log-opt max-size=5m \
  --log-opt max-file=2 \
  --security-opt apparmor=unconfined \
  ${DNS_ARGS[@]+"${DNS_ARGS[@]}"} \
  -v "$HOME_VOLUME":/home/paseo \
  -v "$WORKSPACE_VOLUME":/workspace:rw \
  ${SOCK_ARGS[@]+"${SOCK_ARGS[@]}"} \
  -e PASEO_LISTEN="0.0.0.0:${PASEO_PORT}" \
  -e PASEO_RELAY_ENABLED=true \
  -e PASEO_LOG_CONSOLE_LEVEL=warn \
  -e PASEO_CLAUDE_MAX_LIVE="$CLAUDE_MAX_LIVE" \
  -e PASEO_CLAUDE_IDLE_SECS="$CLAUDE_IDLE_SECS" \
  -e PASEO_CODEX_IDLE_SECS="$CODEX_IDLE_SECS" \
  -e CODEX_API_KEY="$CODEX_API_KEY" \
  -e CODEX_MAX_TOKEN="$CODEX_MAX_TOKEN" \
  -e GH_TOKEN="$GH_TOKEN" \
  -e GH_USERNAME="$GH_USERNAME" \
  -e GH_EMAIL="$GH_EMAIL" \
  -e TERM=xterm-256color \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e DISABLE_TELEMETRY=1 \
  -e DISABLE_ERROR_REPORTING=1 \
  -e DISABLE_AUTOUPDATER=1 \
  -e DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CLAUDE_MAX_OUTPUT_TOKENS" \
  -e BASH_DEFAULT_TIMEOUT_MS=120000 \
  -e BASH_MAX_TIMEOUT_MS=600000 \
  ${opt_env[@]+"${opt_env[@]}"} \
  "$IMAGE" 2>&1); then
  echo "[x] docker run failed:" >&2
  printf '%s\n' "$run_out" | redact >&2
  exit 1
fi
CID=$(printf '%s\n' "$run_out" | tail -n 1)
dbg "docker run ok in $(since "$T_RUN"): id=${CID:0:12}"
if [ "$(printf '%s\n' "$run_out" | wc -l)" -gt 1 ]; then
  dbg "docker run warnings:"
  printf '%s\n' "$run_out" | head -n -1 | redact | sed 's/^/    | /'
fi

# --- Wait until running ---
STATE="missing"
WAITED=0
for _ in 1 2 3 4 5 6 7 8; do
  STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
  [ "$STATE" = "running" ] && break
  WAITED=$((WAITED + 1))
  sleep 1
done
if [ "$STATE" != "running" ]; then
  echo "[x] container not running (state=${STATE})" >&2
  dbg "state detail: $(docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}} error={{.State.Error}}' "$CONTAINER_NAME" 2>/dev/null)"
  docker logs --tail 80 "$CONTAINER_NAME" 2>&1 | redact >&2 || true
  exit 1
fi
echo "[+] container running"
dbg "running after ${WAITED}s of waiting"
dbg "container: $(docker inspect -f 'pid={{.State.Pid}} restarts={{.RestartCount}} policy={{.HostConfig.RestartPolicy.Name}} oom_killed={{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null)"
dbg "limits applied: $(docker inspect -f 'nanocpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}} memswap={{.HostConfig.MemorySwap}} pids={{.HostConfig.PidsLimit}} net={{.HostConfig.NetworkMode}} dns={{.HostConfig.Dns}}' "$CONTAINER_NAME" 2>/dev/null)"

# --- Seed Codex config + clear stale SQLite state ---
# paseo-lite starts its shared codex app-server lazily on the first prompt,
# so writing the config after container start is picked up without a restart.
# Thread mode (read-only / auto / full-access) chosen in the UI overrides the
# sandbox/approval defaults below for agent sessions.
SEED_SCRIPT=$(cat <<'EOF'
set -e
D=/home/paseo/.codex
mkdir -p "$D"
rm -rf "$D/state" "$D"/*.sqlite "$D"/*.sqlite-shm "$D"/*.sqlite-wal 2>/dev/null || true
{
  echo '# Managed by init-paseo-lite.sh - do not edit manually.'
  echo ''
  echo 'sandbox_mode = "danger-full-access"'
  echo 'approval_policy = "never"'
  if [ -n "$CODEX_BASE_URL" ]; then
    echo 'model_provider = "custom"'
    [ -n "$CODEX_MODEL" ] && printf 'model = "%s"\n' "$CODEX_MODEL"
    echo ''
    echo '[model_providers.custom]'
    echo 'name = "Custom"'
    printf 'base_url = "%s"\n' "$CODEX_BASE_URL"
    echo 'env_key = "CODEX_API_KEY"'
    echo 'wire_api = "responses"'
    echo 'stream_max_retries = 100'
    echo 'request_max_retries = 100'
    echo 'stream_idle_timeout_ms = 300000'
  elif [ -n "$CODEX_MODEL" ]; then
    printf 'model = "%s"\n' "$CODEX_MODEL"
  fi
} > "$D/config.toml"
chown -R 1000:1000 "$D"
EOF
)
if seed_out=$(docker exec -i -u 0 \
    -e CODEX_BASE_URL="$CODEX_BASE_URL" -e CODEX_MODEL="$CODEX_MODEL" \
    "$CONTAINER_NAME" sh -s <<<"$SEED_SCRIPT" 2>&1); then
  dbg "codex config seeded: $(docker exec "$CONTAINER_NAME" ls -l /home/paseo/.codex/config.toml 2>&1 | redact)"
  if [ "$INIT_DEBUG" = "1" ]; then
    # base_url is masked: it can embed credentials in some gateways
    docker exec "$CONTAINER_NAME" cat /home/paseo/.codex/config.toml 2>/dev/null \
      | sed -E 's#^(base_url = ")[^"]*"#\1<masked>"#' | redact | sed 's/^/    | /' || true
  fi
else
  echo "[!] codex config seeding failed" >&2
  printf '%s\n' "$seed_out" | redact >&2
fi

# --- Make gh the default git credential helper (uses GH_TOKEN) ---
# Written to ~/.gitconfig in the home volume; safe to repeat.
if gh_out=$(docker exec -u 1000:1000 -e HOME=/home/paseo "$CONTAINER_NAME" sh -c '
  gh auth setup-git --hostname github.com 2>/dev/null \
  || { git config --global --replace-all credential.https://github.com.helper "" \
       && git config --global --add credential.https://github.com.helper "!gh auth git-credential" \
       && git config --global --replace-all credential.https://gist.github.com.helper "" \
       && git config --global --add credential.https://gist.github.com.helper "!gh auth git-credential"; }
' 2>&1); then
  echo "[+] gh set as git credential helper"
  dbg "git credential helpers: $(docker exec -u 1000:1000 -e HOME=/home/paseo "$CONTAINER_NAME" git config --global --get-all credential.https://github.com.helper 2>&1 | paste -sd'|' - | redact)"
  dbg "gh auth status: $(docker exec -u 1000:1000 -e HOME=/home/paseo "$CONTAINER_NAME" gh auth status 2>&1 | head -n 3 | paste -sd' ' - | redact || true)"
else
  echo "[!] gh git credential setup failed" >&2
  printf '%s\n' "$gh_out" | redact >&2
fi

# --- Post-start health (debug only, never fails the run) ---
if [ "$INIT_DEBUG" = "1" ]; then
  sleep 3
  S2=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)
  R2=$(docker inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo "?")
  O2=$(docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo "?")
  dbg "3s after start: status=${S2} restarts=${R2} oom_killed=${O2}"
  if [ "$S2" != "running" ] || [ "$R2" != "0" ]; then
    echo "[!] container looks unstable (status=${S2}, restarts=${R2}, oom_killed=${O2}); recent logs:" >&2
    docker logs --tail 40 "$CONTAINER_NAME" 2>&1 | redact | sed 's/^/    | /' >&2 || true
  fi

  LISTENING="no"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if [ -n "$(ss -Hltn "sport = :${PASEO_PORT}" 2>/dev/null)" ]; then LISTENING="yes"; break; fi
    sleep 1
  done
  dbg "listening on :${PASEO_PORT}: ${LISTENING}"
  [ "$LISTENING" = "yes" ] || echo "[!] nothing is listening on :${PASEO_PORT} yet (may still be starting; check: docker logs ${CONTAINER_NAME})" >&2

  dbg "usage: $(dk stats --no-stream --format 'cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}' "$CONTAINER_NAME" 2>/dev/null || echo n/a)"
  dbg "host memory now: $(free -m | awk '/^Mem:/{printf "used=%sMB avail=%sMB", $3,$7}') | load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  dbg "recent container logs (last 15 lines, redacted):"
  docker logs --tail 15 "$CONTAINER_NAME" 2>&1 | redact | sed 's/^/    | /' || true
fi

# The pairing link is a credential for the relay - never print it in CI logs.
echo "[*] pair a device on the VM: docker exec ${CONTAINER_NAME} paseo-lite pair"
echo "[+] init done"
dbg "total time: $(since "$T_START")"
exit 0

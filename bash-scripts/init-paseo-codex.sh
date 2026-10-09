#!/bin/bash
# bash-scripts/init-paseo-codex.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Target: GCP free-tier e2-micro (0.5 vCPU shared, 1 GB RAM)
# Only ONE container is ever used: paseo-codex (no helper/alpine containers).

set -euo pipefail

CODEX_BASE_URL="${CODEX_BASE_URL:-}"
CODEX_API_KEY="${CODEX_API_KEY:-}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_MAX_TOKEN="${CODEX_MAX_TOKEN:-8192}"
GH_TOKEN="${GH_TOKEN:-}"

# --- Claude Code (all optional; see original notes) -------------------
# Auth option 1: subscription -> CLAUDE_CODE_OAUTH_TOKEN, or `claude /login`
#                inside the container (persists in the paseo-home volume).
# Auth option 2: API key (ANTHROPIC_API_KEY) or BYOK gateway
#                (ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN).
# Unset values are not forwarded, so they never appear as empty strings.
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"

PASEO_PORT="${PASEO_PORT:-6767}"
# Daemon listens on 0.0.0.0 (host network) - set a password so it isn't open.
PASEO_PASSWORD="${PASEO_PASSWORD:-}"

# --- Resource caps (kernel-enforced via cgroups) ----------------------
# Memory has a hard floor of 256 MB: anything lower gets bumped up.
MIN_MEM_MB=256
CPU_LIMIT="${CPU_LIMIT:-0.40}"
# 448m: supervisor + worker are two Node processes and the startup plugin burst
# (codex/copilot/cursor/grok/kimi/minimax...) spikes memory. 320m got SIGKILLed.
MEM_LIMIT="${MEM_LIMIT:-448m}"
MEM_SWAP_LIMIT="${MEM_SWAP_LIMIT:-640m}"   # total memory+swap (small: swap burns CPU/IO)
PIDS_LIMIT="${PIDS_LIMIT:-192}"
# --max-old-space-size applies PER Node process, so keep it modest.
NODE_HEAP_MB="${NODE_HEAP_MB:-160}"
HEARTBEAT_CRON="${HEARTBEAT_CRON:-0 * * * *}"

IMAGE="sudtanj/paseo-codex:latest"
CONTAINER_NAME="paseo-codex"

to_mb() {
  case "$1" in
    *[gG]) echo $(( ${1%[gG]} * 1024 )) ;;
    *[mM]) echo "${1%[mM]}" ;;
    *)     echo "$1" ;;
  esac
}

echo "[*] init start"

# --- Validate env ---
missing=()
[ -z "$CODEX_API_KEY" ] && missing+=("CODEX_API_KEY")
[ -z "$GH_TOKEN" ]      && missing+=("GH_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[x] missing required env: ${missing[*]}" >&2
  exit 1
fi
echo "[+] env ok"
if [ -z "$PASEO_PASSWORD" ]; then
  echo "[!] PASEO_PASSWORD not set - daemon accepts unauthenticated connections on :${PASEO_PORT}" >&2
fi

# --- Normalise memory settings (enforce 256 MB floor) ---
MEM_MB=$(to_mb "$MEM_LIMIT")
SWAP_MB=$(to_mb "$MEM_SWAP_LIMIT")
if [ "$MEM_MB" -lt "$MIN_MEM_MB" ]; then
  echo "[!] MEM_LIMIT ${MEM_LIMIT} below ${MIN_MEM_MB}m floor - using ${MIN_MEM_MB}m" >&2
  MEM_MB=$MIN_MEM_MB
fi
[ "$SWAP_MB" -lt "$MEM_MB" ] && SWAP_MB=$MEM_MB       # memory+swap can't be < memory
MEM_RES_MB=$(( MEM_MB * 80 / 100 ))                   # soft limit, always < hard limit
HEAP_CAP=$(( MEM_MB * 60 / 100 ))                     # leave room for native/off-heap
[ "$NODE_HEAP_MB" -gt "$HEAP_CAP" ] && NODE_HEAP_MB=$HEAP_CAP

# --- Always pull the latest image (before touching the running container) ---
echo "[>] pulling latest ${IMAGE}"
PREV_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo "none")
if ! docker pull -q "$IMAGE" >/dev/null; then
  echo "[x] docker pull ${IMAGE} failed - current container left untouched" >&2
  exit 1
fi
NEW_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo "unknown")
if [ "$PREV_ID" = "none" ]; then
  echo "[+] image pulled (first pull on this VM)"
elif [ "$PREV_ID" = "$NEW_ID" ]; then
  echo "[+] image already up to date"
else
  echo "[+] image updated to a newer build"
  docker image prune -f >/dev/null 2>&1 || true      # reclaim old layers only when changed
fi

# --- Skip the restart if nothing changed ---
# A hash of image digest + every setting is stored as a container label.
# Same hash + running container = no recreate (saves CPU, avoids downtime).
CONFIG_HASH=$(printf '%s\n' "$NEW_ID" "$CODEX_BASE_URL" "$CODEX_API_KEY" "$CODEX_MODEL" \
  "$CODEX_MAX_TOKEN" "$GH_TOKEN" "$ANTHROPIC_API_KEY" "$ANTHROPIC_AUTH_TOKEN" \
  "$ANTHROPIC_BASE_URL" "$ANTHROPIC_MODEL" "$CLAUDE_CODE_OAUTH_TOKEN" "$PASEO_PORT" "$PASEO_PASSWORD" \
  "$CPU_LIMIT" "$MEM_MB" "$SWAP_MB" "$PIDS_LIMIT" "$NODE_HEAP_MB" \
  | sha256sum | cut -d' ' -f1)
CUR_HASH=$(docker inspect -f '{{ index .Config.Labels "init.hash" }}' "$CONTAINER_NAME" 2>/dev/null || echo "")
RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")

if [ "$CUR_HASH" = "$CONFIG_HASH" ] && [ "$RUNNING" = "true" ]; then
  echo "[+] config and image unchanged - container left running"
  echo "[+] init done"
  exit 0
fi

# --- Recreate the single container ---
echo "[>] replacing $CONTAINER_NAME"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume create paseo-home      >/dev/null
docker volume create paseo-workspace >/dev/null

# Forward only the Claude Code vars that are actually set.
claude_env=()
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
         ANTHROPIC_MODEL CLAUDE_CODE_OAUTH_TOKEN PASEO_PASSWORD; do
  if [ -n "${!v:-}" ]; then
    claude_env+=(-e "$v=${!v}")
  fi
done

# apparmor=unconfined is required for bwrap to create user namespaces.
# CPU notes:
#  - UV_THREADPOOL_SIZE=2 and a small semi-space keep GC/thread churn low.
#  - Health check every 120s (each check spawns curl).
docker run -d --name "$CONTAINER_NAME" --restart always \
  --label "init.hash=${CONFIG_HASH}" \
  --user 1000:1000 \
  --network=host \
  --cpus "$CPU_LIMIT" \
  --cpu-shares 256 \
  --memory "${MEM_MB}m" \
  --memory-reservation "${MEM_RES_MB}m" \
  --memory-swap "${SWAP_MB}m" \
  --memory-swappiness 30 \
  --pids-limit "$PIDS_LIMIT" \
  --ulimit nofile=4096:4096 \
  --ulimit nproc=512:512 \
  --ulimit core=0 \
  --oom-score-adj 500 \
  --log-driver json-file \
  --log-opt max-size=5m \
  --log-opt max-file=2 \
  --tmpfs /tmp:rw,nosuid,size=64m \
  --security-opt apparmor=unconfined \
  --dns 2a00:1098:2b::1 \
  --dns 2a01:4f9:c010:3f02::1 \
  --health-cmd "curl -fsS --max-time 3 http://127.0.0.1:${PASEO_PORT}/api/health || exit 1" \
  --health-interval=120s \
  --health-retries=3 \
  --health-start-period=90s \
  --health-timeout=5s \
  -v paseo-home:/home/paseo \
  -v paseo-workspace:/workspace:rw \
  -e CODEX_BASE_URL="$CODEX_BASE_URL" \
  -e CODEX_API_KEY="$CODEX_API_KEY" \
  -e CODEX_MODEL="$CODEX_MODEL" \
  -e CODEX_MAX_TOKEN="$CODEX_MAX_TOKEN" \
  -e GH_TOKEN="$GH_TOKEN" \
  -e TERM=xterm-256color \
  -e NODE_OPTIONS="--max-old-space-size=${NODE_HEAP_MB} --max-semi-space-size=8" \
  -e UV_THREADPOOL_SIZE=2 \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e DISABLE_TELEMETRY=1 \
  -e DISABLE_ERROR_REPORTING=1 \
  -e DISABLE_AUTOUPDATER=1 \
  -e DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192 \
  -e BASH_DEFAULT_TIMEOUT_MS=120000 \
  -e BASH_MAX_TIMEOUT_MS=600000 \
  ${claude_env[@]+"${claude_env[@]}"} \
  "$IMAGE" \
  >/dev/null 2>&1

# --- Wait for the container to be up (poll instead of a fixed sleep) ---
echo "[>] verifying container"
STATE="missing"
for _ in 1 2 3 4 5 6 7 8; do
  STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
  [ "$STATE" = "running" ] && break
  sleep 1
done
if [ "$STATE" != "running" ]; then
  echo "[x] container not running (state=${STATE})" >&2
  docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
  exit 1
fi
echo "[+] container running"

# --- Seed Codex config INSIDE paseo-codex (no helper container) ---
# Runs as root only to fix ownership; Codex reads config per session, so no
# restart is needed. Stale SQLite state is wiped here too.
echo "[>] seeding Codex config"
docker exec -i -u 0 "$CONTAINER_NAME" sh -s >/dev/null 2>&1 <<'EOF' || echo "[!] codex config seeding failed" >&2
set -e
D=/home/paseo/.codex
mkdir -p "$D"
rm -rf "$D/state" "$D"/*.sqlite "$D"/*.sqlite-shm "$D"/*.sqlite-wal 2>/dev/null || true
cat > "$D/config.toml" <<'TOML'
# Managed by init-paseo-codex.sh - do not edit manually.

sandbox_mode = "danger-full-access"
approval_policy = "never"

[model_providers.custom]
stream_max_retries = 100
request_max_retries = 100
stream_idle_timeout_ms = 300000
TOML
chown -R 1000:1000 "$D"
EOF
echo "[+] Codex config seeded, stale state cleared"

# --- AppArmor check (host-side inspect, no exec) ---
if docker inspect -f '{{.HostConfig.SecurityOpt}}' "$CONTAINER_NAME" 2>/dev/null | grep -q "apparmor=unconfined"; then
  echo "[+] AppArmor is unconfined (bwrap can create namespaces)"
else
  echo "[!] AppArmor is NOT unconfined - bwrap may still fail" >&2
fi

# --- Claude Code auth: env-based paths need no exec at all ---
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo "[+] Claude Code auth: subscription token (CLAUDE_CODE_OAUTH_TOKEN)"
  CLAUDE_AUTH_DONE=1
elif [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "[+] Claude Code auth: API-key billing (ANTHROPIC_API_KEY)"
  CLAUDE_AUTH_DONE=1
elif [ -n "$ANTHROPIC_AUTH_TOKEN" ] && [ -n "$ANTHROPIC_BASE_URL" ]; then
  echo "[+] Claude Code auth: BYOK gateway (ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL)"
  CLAUDE_AUTH_DONE=1
else
  CLAUDE_AUTH_DONE=0
fi

# --- ONE exec for all in-container checks + heartbeat ---
# (Each `docker exec` + `paseo` call starts a Node process, which is costly on
# 0.5 vCPU, so everything is batched and paseo is invoked at most twice.)
docker exec -e HEARTBEAT_CRON="$HEARTBEAT_CRON" -e CLAUDE_AUTH_DONE="$CLAUDE_AUTH_DONE" \
  "$CONTAINER_NAME" sh -s 2>/dev/null <<'EOF' || true
if touch /home/paseo/.codex/.writetest 2>/dev/null; then
  rm -f /home/paseo/.codex/.writetest
  echo "[+] .codex writable"
else
  echo "[x] .codex NOT writable"
fi

if [ "$CLAUDE_AUTH_DONE" != "1" ]; then
  if [ -f /home/paseo/.claude/.credentials.json ]; then
    echo "[+] Claude Code auth: stored claude /login credentials in paseo-home"
  else
    echo "[!] no Claude Code auth configured - set CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY) as a repo secret, or run claude /login inside the container"
  fi
fi

# Memory straight from cgroup (cgroup v2, then v1) - avoids `docker stats`.
if [ -r /sys/fs/cgroup/memory.current ]; then
  echo "[i] memory: $(( $(cat /sys/fs/cgroup/memory.current) / 1048576 )) MiB"
elif [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
  echo "[i] memory: $(( $(cat /sys/fs/cgroup/memory/memory.usage_in_bytes) / 1048576 )) MiB"
fi

if command -v paseo >/dev/null 2>&1; then
  if paseo heartbeat ls 2>/dev/null | grep -q heartbeat; then
    echo "[+] heartbeat exists"
  elif paseo heartbeat create --cron "$HEARTBEAT_CRON" --name heartbeat \
         "Check the current task state and continue with the next useful step." >/dev/null 2>&1; then
    echo "[+] heartbeat created"
  else
    echo "[!] heartbeat creation failed - set it up manually inside an agent session"
  fi
fi
EOF

# --- Host-side status (cheap inspects only) ---
echo "[i] health: $(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
echo "[i] network mode: $(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")"
OOM_INFO=$(docker inspect -f '{{.State.OOMKilled}} restarts={{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
echo "[i] oom-killed: ${OOM_INFO}"
case "$OOM_INFO" in
  true*) echo "[!] container was OOM-killed - raise MEM_LIMIT (e.g. 512m)" >&2 ;;
esac
if ip link show tailscale0 >/dev/null 2>&1; then
  echo "[+] tailscale0 visible"
else
  echo "[!] tailscale0 not present - tailnet access will not work" >&2
fi
echo "[i] hard caps: cpu=${CPU_LIMIT} mem=${MEM_MB}m mem+swap=${SWAP_MB}m heap=${NODE_HEAP_MB}m pids=${PIDS_LIMIT}"

echo "[+] init done"
exit 0

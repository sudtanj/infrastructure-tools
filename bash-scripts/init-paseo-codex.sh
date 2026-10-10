#!/bin/bash
# bash-scripts/init-paseo-codex.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Target: GCP free-tier e2-micro (1 GB RAM). One container: paseo-codex.

set -euo pipefail

CODEX_BASE_URL="${CODEX_BASE_URL:-}"
CODEX_API_KEY="${CODEX_API_KEY:-}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_MAX_TOKEN="${CODEX_MAX_TOKEN:-8192}"
GH_TOKEN="${GH_TOKEN:-}"

# Claude Code auth (optional): OAuth token, API key, or BYOK gateway.
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"

PASEO_PORT="${PASEO_PORT:-6767}"
PASEO_PASSWORD="${PASEO_PASSWORD:-}"

# --- Resources (host safety first: sshd/tailscale must always stay reachable) ---
# e2-micro = 1 GB RAM, shared core (0.25 vCPU sustained, bursts to 2).
# CPU cap leaves headroom for the host; low --cpu-shares makes others win.
# Container swap disabled (memory-swap == memory): a clean OOM-kill of the
# container + auto-restart beats thrashing. Host gets its own swap below.
CPU_LIMIT="${CPU_LIMIT:-0.75}"
MEM_MB="${MEM_MB:-640}"
PIDS_LIMIT="${PIDS_LIMIT:-256}"
NODE_HEAP_MB="${NODE_HEAP_MB:-224}"
HEARTBEAT_CRON="${HEARTBEAT_CRON:-0 * * * *}"

IMAGE="sudtanj/paseo-codex:latest"
CONTAINER_NAME="paseo-codex"

echo "[*] init start"

# --- Validate env ---
missing=()
[ -z "$CODEX_API_KEY" ] && missing+=("CODEX_API_KEY")
[ -z "$GH_TOKEN" ]      && missing+=("GH_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[x] missing required env: ${missing[*]}" >&2
  exit 1
fi
[ -z "$PASEO_PASSWORD" ] && echo "[!] PASEO_PASSWORD not set - daemon is unauthenticated on :${PASEO_PORT}" >&2

# --- Host protection (idempotent, best-effort, never restarts sshd) ---
# 1) Host swapfile so a memory spike doesn't hang the VM.
if [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then
  echo "[>] creating 1G host swapfile"
  if sudo -n sh -c 'fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile' 2>/dev/null; then
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo -n tee -a /etc/fstab >/dev/null
  else
    echo "[!] swapfile creation failed (no sudo or no disk space)" >&2
  fi
fi
sudo -n sysctl -q vm.swappiness=10 2>/dev/null || true
# 2) Make the kernel OOM-killer avoid sshd/tailscaled/docker (applies on their next restart).
for svc in ssh sshd tailscaled docker; do
  if systemctl cat "$svc" >/dev/null 2>&1; then
    f="/etc/systemd/system/${svc}.service.d/oom.conf"
    if [ ! -f "$f" ]; then
      sudo -n mkdir -p "$(dirname "$f")" 2>/dev/null \
        && printf '[Service]\nOOMScoreAdjust=-900\n' | sudo -n tee "$f" >/dev/null 2>&1 || true
    fi
  fi
done
sudo -n systemctl daemon-reload 2>/dev/null || true
sudo -n systemctl enable docker >/dev/null 2>&1 || true

# --- Pull latest image before touching the running container ---
PREV_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo "none")
if ! docker pull -q "$IMAGE" >/dev/null; then
  echo "[x] docker pull failed - current container left untouched" >&2
  exit 1
fi
NEW_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo "unknown")
[ "$PREV_ID" != "none" ] && [ "$PREV_ID" != "$NEW_ID" ] && docker image prune -f >/dev/null 2>&1 || true

# --- Skip restart if nothing changed ---
CONFIG_HASH=$(printf '%s\n' "$NEW_ID" "$CODEX_BASE_URL" "$CODEX_API_KEY" "$CODEX_MODEL" \
  "$CODEX_MAX_TOKEN" "$GH_TOKEN" "$ANTHROPIC_API_KEY" "$ANTHROPIC_AUTH_TOKEN" \
  "$ANTHROPIC_BASE_URL" "$ANTHROPIC_MODEL" "$CLAUDE_CODE_OAUTH_TOKEN" \
  "$PASEO_PORT" "$PASEO_PASSWORD" "$CPU_LIMIT" "$MEM_MB" "$PIDS_LIMIT" "$NODE_HEAP_MB" \
  | sha256sum | cut -d' ' -f1)
CUR_HASH=$(docker inspect -f '{{ index .Config.Labels "init.hash" }}' "$CONTAINER_NAME" 2>/dev/null || echo "")
RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo "false")

if [ "$CUR_HASH" = "$CONFIG_HASH" ] && [ "$RUNNING" = "true" ]; then
  echo "[+] unchanged - container left running"
  exit 0
fi

# --- Recreate the container ---
echo "[>] replacing $CONTAINER_NAME"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker volume create paseo-home      >/dev/null
docker volume create paseo-workspace >/dev/null

claude_env=()
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
         ANTHROPIC_MODEL CLAUDE_CODE_OAUTH_TOKEN PASEO_PASSWORD; do
  [ -n "${!v:-}" ] && claude_env+=(-e "$v=${!v}")
done

# apparmor=unconfined is required for bwrap to create user namespaces.
# --restart always: restarts on crash, OOM kill, and Docker/VM reboot.
docker run -d --name "$CONTAINER_NAME" --restart always \
  --label "init.hash=${CONFIG_HASH}" \
  --user 1000:1000 \
  --network=host \
  --cpus "$CPU_LIMIT" \
  --cpu-shares 128 \
  --memory "${MEM_MB}m" \
  --memory-reservation "$(( MEM_MB * 80 / 100 ))m" \
  --memory-swap "${MEM_MB}m" \
  --pids-limit "$PIDS_LIMIT" \
  --ulimit nproc=512:512 \
  --ulimit core=0 \
  --oom-score-adj 500 \
  --log-driver json-file \
  --log-opt max-size=5m \
  --log-opt max-file=2 \
  --security-opt apparmor=unconfined \
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
  "$IMAGE" >/dev/null 2>&1

# --- Wait until running ---
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

# --- Seed Codex config + clear stale SQLite state ---
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

# --- Heartbeat (single exec) ---
docker exec -e HEARTBEAT_CRON="$HEARTBEAT_CRON" "$CONTAINER_NAME" sh -s >/dev/null 2>&1 <<'EOF' || true
command -v paseo >/dev/null 2>&1 || exit 0
paseo heartbeat ls 2>/dev/null | grep -q heartbeat && exit 0
paseo heartbeat create --cron "$HEARTBEAT_CRON" --name heartbeat \
  "Check the current task state and continue with the next useful step."
EOF

echo "[+] init done"
exit 0

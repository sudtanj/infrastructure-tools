#!/bin/bash
# bash-scripts/init-paseo-lite.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Target: GCP free-tier e2-micro (1 GB RAM). One container: paseo-lite
# (Rust Paseo daemon + native Claude Code + native Codex, no Node.js).
# Same secrets as init-paseo-codex.sh: CODEX_*, GH_TOKEN, ANTHROPIC_*, CLAUDE_CODE_*.

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

# 6768 so it can coexist with paseo-codex (6767) on the same host network.
PASEO_PORT="${PASEO_LITE_PORT:-6768}"
PASEO_PASSWORD="${PASEO_PASSWORD:-}"

# --- Resources (host safety first: sshd/tailscale must always stay reachable) ---
# The daemon itself needs a few MB; the cap is for the agent CLIs it runs.
# paseo-lite shares one codex app-server across projects and caps concurrent
# claude processes (PASEO_CLAUDE_MAX_LIVE), so the budget is predictable.
# Container swap disabled (memory-swap == memory): a clean OOM-kill of the
# container + auto-restart beats thrashing. Host gets its own swap below.
CPU_LIMIT="${CPU_LIMIT:-0.75}"
MEM_MB="${MEM_MB:-640}"
PIDS_LIMIT="${PIDS_LIMIT:-256}"
CLAUDE_MAX_LIVE="${PASEO_CLAUDE_MAX_LIVE:-1}"
CLAUDE_IDLE_SECS="${PASEO_CLAUDE_IDLE_SECS:-60}"
CODEX_IDLE_SECS="${PASEO_CODEX_IDLE_SECS:-300}"

# Bump this whenever the docker run flags change (DNS, limits, etc.) so the
# container is recreated; the hash below only covers values, not the flags.
CONFIG_REV="1"
DNS1="2a00:1098:2b::1"
DNS2="2a01:4f9:c010:3f02::1"

IMAGE="sudtanj/paseo-lite:latest"
CONTAINER_NAME="paseo-lite"
HOME_VOLUME="paseo-lite-home"
WORKSPACE_VOLUME="paseo-workspace"

echo "[*] init start"

# --- Validate env ---
missing=()
[ -z "$CODEX_API_KEY" ] && missing+=("CODEX_API_KEY")
[ -z "$GH_TOKEN" ]      && missing+=("GH_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[x] missing required env: ${missing[*]}" >&2
  exit 1
fi
[ -z "$PASEO_PASSWORD" ] && echo "[!] PASEO_PASSWORD not set - direct connections on :${PASEO_PORT} are unauthenticated (relay clients still need the pairing key)" >&2

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
  "$PASEO_PORT" "$PASEO_PASSWORD" "$CPU_LIMIT" "$MEM_MB" "$PIDS_LIMIT" \
  "$CLAUDE_MAX_LIVE" "$CLAUDE_IDLE_SECS" "$CODEX_IDLE_SECS" "$CONFIG_REV" "$DNS1" "$DNS2" \
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
docker volume create "$HOME_VOLUME"      >/dev/null
docker volume create "$WORKSPACE_VOLUME" >/dev/null

# Only forward secrets that are actually set.
opt_env=()
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
         ANTHROPIC_MODEL CLAUDE_CODE_OAUTH_TOKEN PASEO_PASSWORD CODEX_MODEL; do
  [ -n "${!v:-}" ] && opt_env+=(-e "$v=${!v}")
done

# CODEX_BASE_URL is deliberately NOT passed into the container: this script
# writes the complete Codex provider config itself (below), so the image's
# start-time generator must not append a second [model_providers.custom].
#
# apparmor=unconfined is required for bwrap to create user namespaces
# (Codex sandbox). --dns: DNS64 resolvers (nat64.net) so IPv6-only hosts
# can reach IPv4-only services like github.com. Docker applies these even
# with --network=host. --restart always: restarts on crash, OOM kill, and
# Docker/VM reboot.
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
  --dns "$DNS1" \
  --dns "$DNS2" \
  -v "$HOME_VOLUME":/home/paseo \
  -v "$WORKSPACE_VOLUME":/workspace:rw \
  -e PASEO_LISTEN="0.0.0.0:${PASEO_PORT}" \
  -e PASEO_RELAY_ENABLED=true \
  -e PASEO_LOG_CONSOLE_LEVEL=warn \
  -e PASEO_CLAUDE_MAX_LIVE="$CLAUDE_MAX_LIVE" \
  -e PASEO_CLAUDE_IDLE_SECS="$CLAUDE_IDLE_SECS" \
  -e PASEO_CODEX_IDLE_SECS="$CODEX_IDLE_SECS" \
  -e CODEX_API_KEY="$CODEX_API_KEY" \
  -e CODEX_MAX_TOKEN="$CODEX_MAX_TOKEN" \
  -e GH_TOKEN="$GH_TOKEN" \
  -e TERM=xterm-256color \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  -e DISABLE_TELEMETRY=1 \
  -e DISABLE_ERROR_REPORTING=1 \
  -e DISABLE_AUTOUPDATER=1 \
  -e DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS=8192 \
  -e BASH_DEFAULT_TIMEOUT_MS=120000 \
  -e BASH_MAX_TIMEOUT_MS=600000 \
  ${opt_env[@]+"${opt_env[@]}"} \
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
# paseo-lite starts its shared codex app-server lazily on the first prompt,
# so writing the config after container start is picked up without a restart.
# Thread mode (read-only / auto / full-access) chosen in the UI overrides the
# sandbox/approval defaults below for agent sessions.
docker exec -i -u 0 \
  -e CODEX_BASE_URL="$CODEX_BASE_URL" -e CODEX_MODEL="$CODEX_MODEL" \
  "$CONTAINER_NAME" sh -s >/dev/null 2>&1 <<'EOF' || echo "[!] codex config seeding failed" >&2
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

# --- Make gh the default git credential helper (uses GH_TOKEN) ---
# Written to ~/.gitconfig in the home volume; safe to repeat.
docker exec -u 1000:1000 -e HOME=/home/paseo "$CONTAINER_NAME" sh -c '
  gh auth setup-git --hostname github.com 2>/dev/null \
  || { git config --global --replace-all credential.https://github.com.helper "" \
       && git config --global --add credential.https://github.com.helper "!gh auth git-credential" \
       && git config --global --replace-all credential.https://gist.github.com.helper "" \
       && git config --global --add credential.https://gist.github.com.helper "!gh auth git-credential"; }
' >/dev/null 2>&1 && echo "[+] gh set as git credential helper" || echo "[!] gh git credential setup failed" >&2

# The pairing link is a credential for the relay - never print it in CI logs.
echo "[*] pair a device on the VM: docker exec ${CONTAINER_NAME} paseo-lite pair"
echo "[+] init done"
exit 0

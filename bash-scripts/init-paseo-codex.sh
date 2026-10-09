#!/bin/bash
# bash-scripts/init-paseo-codex.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Target: GCP free-tier e2-micro (384 MB allocation, 0.5 vCPU)

set -euo pipefail

CODEX_BASE_URL="${CODEX_BASE_URL:-}"
CODEX_API_KEY="${CODEX_API_KEY:-}"
CODEX_MODEL="${CODEX_MODEL:-}"
CODEX_MAX_TOKEN="${CODEX_MAX_TOKEN:-8192}"
GH_TOKEN="${GH_TOKEN:-}"

# --- Claude Code -----------------------------------------------------
# Read natively by Claude Code from the environment on every launch -
# no config file is generated, and Paseo passes them straight through
# to the sessions it launches (like OPENAI_API_KEY does for Codex).
#
# AUTH OPTION 1 - subscription (Pro/Max), the default here: leave
# ANTHROPIC_API_KEY unset and instead either run `claude /login` once
# inside the container (OAuth credentials persist in the paseo-home
# volume) ...
#   ANTHROPIC_API_KEY: sk-ant-...   <- API-key billing only; leave unset for subscription
# ... or generate a token with `claude setup-token` on your own
# machine and set it here - charges your subscription, not usage:
#   CLAUDE_CODE_OAUTH_TOKEN: ...
#
# AUTH OPTION 2 - Claude Code BYOK: point at your own
# Anthropic-API-compatible endpoint instead of api.anthropic.com.
# ANTHROPIC_AUTH_TOKEN is sent as an Authorization: Bearer header
# instead of x-api-key - for gateways that want a bearer token.
#   ANTHROPIC_BASE_URL: https://my-gateway.internal
#   ANTHROPIC_AUTH_TOKEN: ...
# Optional default model, e.g. claude-sonnet-5-5 (unset = Claude
# Code's own built-in default).
#   ANTHROPIC_MODEL: claude-sonnet-5-5
#
# All five are optional. Values arrive as GitHub repo secrets with the
# ANTHROPIC_ / CLAUDE_CODE_ prefixes (see SECRET_FILTER in
# .github/workflows/gcp-bash-script-runner.yaml) and are only forwarded
# to the container when actually set - an unset secret stays absent from
# the environment rather than landing in it as an empty string.
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}"
CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"

PASEO_PORT="${PASEO_PORT:-6767}"

# --- Hard resource caps (enforced by the kernel via cgroups) ---
# Sized to leave room for tailscaled/n8n/docker on the 1 GB e2-micro. Swap is
# kept small: heavy swapping burns free-tier disk IO and CPU, so a runaway
# session gets OOM-killed (and restarted) instead of dragging the VM down.
CPU_LIMIT="${CPU_LIMIT:-0.40}"
MEM_LIMIT="${MEM_LIMIT:-320m}"
MEM_SWAP_LIMIT="${MEM_SWAP_LIMIT:-448m}"   # total memory+swap
PIDS_LIMIT="${PIDS_LIMIT:-192}"
NODE_HEAP_MB="${NODE_HEAP_MB:-192}"
HEARTBEAT_CRON="${HEARTBEAT_CRON:-0 * * * *}"

IMAGE="sudtanj/paseo-codex:latest"
CONTAINER_NAME="paseo-codex"
CODEX_CONFIG_DIR="/home/paseo/.codex"
CODEX_CONFIG_FILE="${CODEX_CONFIG_DIR}/config.toml"

echo "[*] init start"

# --- Validate env ---
echo "[>] checking required env"
missing=()
[ -z "$CODEX_API_KEY" ] && missing+=("CODEX_API_KEY")
[ -z "$GH_TOKEN" ]      && missing+=("GH_TOKEN")
if [ "${#missing[@]}" -gt 0 ]; then
  echo "[x] missing required env: ${missing[*]}" >&2
  exit 1
fi
echo "[+] env ok"

# --- Always pull the latest image ---
# Every run re-checks the registry and swaps in a new digest when one has
# been published. This happens BEFORE the running container is touched, so
# a failed pull (registry outage, no egress) leaves the current deployment
# running instead of taking the service down.
echo "[>] pulling latest ${IMAGE}"
PREV_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || echo "none")
# Pull chatter goes to stderr so the script's stdout stays uniformly
# prefixed ([*] [>] [+] [!] [x]) for the runner's log grep.
if ! docker pull "$IMAGE" >&2; then
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
fi

# Reclaim disk from superseded image layers (free-tier disk is small).
docker image prune -f >/dev/null 2>&1 || true

# --- Remove existing container ---
echo "[>] removing existing container"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
echo "[+] cleanup done"

# --- Ensure volumes ---
docker volume create paseo-home      >/dev/null
docker volume create paseo-workspace >/dev/null

# --- Wipe stale/corrupt Codex SQLite state ---
echo "[>] clearing stale Codex state"
docker run --rm --cpus 0.25 --memory 64m --memory-swap 64m --pids-limit 32 \
  -v paseo-home:/home/paseo alpine:latest sh -c '
  rm -rf /home/paseo/.codex/state \
         /home/paseo/.codex/*.sqlite \
         /home/paseo/.codex/*.sqlite-shm \
         /home/paseo/.codex/*.sqlite-wal 2>/dev/null || true
' >/dev/null 2>&1
echo "[+] state cleared"

# --- Seed Codex config into the persistent volume ---
# These settings are for Codex CLI. Paseo may override them with its own
# sandbox preset, but they are still correct to have.
echo "[>] seeding Codex config"
docker run --rm --cpus 0.25 --memory 64m --memory-swap 64m --pids-limit 32 \
  -v paseo-home:"$CODEX_CONFIG_DIR" alpine:latest sh -c "
  mkdir -p '$CODEX_CONFIG_DIR'
  cat > '$CODEX_CONFIG_FILE' <<'EOF'
# Managed by init-paseo-codex.sh — do not edit manually.

sandbox_mode = \"danger-full-access\"
approval_policy = \"never\"

[model_providers.custom]
stream_max_retries = 100
request_max_retries = 100
stream_idle_timeout_ms = 300000
EOF
  chown -R 1000:1000 '/home/paseo'
" >/dev/null 2>&1
echo "[+] Codex config seeded"

# --- Start container ---
# KEY FIX: --security-opt apparmor=unconfined
# This is required for bwrap to create user namespaces inside the container.
echo "[>] starting $CONTAINER_NAME"

# Forward only the Claude Code vars that are actually set. Building the
# -e flags in an array keeps tokens with spaces/quotes intact, and keeps
# an absent secret from becoming an empty-string env var in the container.
claude_env=()
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
         ANTHROPIC_MODEL CLAUDE_CODE_OAUTH_TOKEN; do
  if [ -n "${!v:-}" ]; then
    claude_env+=(-e "$v=${!v}")
  fi
done

docker run -d --name "$CONTAINER_NAME" --restart always \
  --user 1000:1000 \
  --network=host \
  --init \
  --cpus "$CPU_LIMIT" \
  --cpu-shares 256 \
  --memory "$MEM_LIMIT" \
  --memory-reservation 384m \
  --memory-swap "$MEM_SWAP_LIMIT" \
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
  --health-interval=60s \
  --health-retries=3 \
  --health-start-period=45s \
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

sleep 8

# --- Verify container running ---
echo "[>] verifying container"
STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
if [ "$STATE" != "running" ]; then
  echo "[x] container not running (state=${STATE})" >&2
  docker logs --tail 80 "$CONTAINER_NAME" >&2 || true
  exit 1
fi
echo "[+] container running"

# --- Verify AppArmor is unconfined ---
APPA=$(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$CONTAINER_NAME" 2>/dev/null || echo "")
if echo "$APPA" | grep -q "apparmor=unconfined"; then
  echo "[+] AppArmor is unconfined (bwrap can create namespaces)"
else
  echo "[!] AppArmor is NOT unconfined — bwrap may still fail" >&2
fi

# --- Verify sandbox_mode is set ---
docker exec "$CONTAINER_NAME" sh -c '
  grep -q "sandbox_mode = \"danger-full-access\"" /home/paseo/.codex/config.toml 2>/dev/null \
    && echo "[+] sandbox_mode = danger-full-access present" \
    || echo "[!] sandbox_mode missing"
' || true

# --- Verify .codex is writable ---
docker exec "$CONTAINER_NAME" sh -c '
  touch /home/paseo/.codex/.writetest && rm -f /home/paseo/.codex/.writetest \
    && echo "[+] .codex writable" \
    || echo "[x] .codex NOT writable"
' || true

# --- Claude Code auth status (report-only, never fatal) ---
# Which of the three auth paths is live. Deliberately logs names only:
# the runner surfaces [+]/[!] lines into the workflow log.
if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
  echo "[+] Claude Code auth: subscription token (CLAUDE_CODE_OAUTH_TOKEN)"
elif [ -n "$ANTHROPIC_API_KEY" ]; then
  echo "[+] Claude Code auth: API-key billing (ANTHROPIC_API_KEY)"
elif [ -n "$ANTHROPIC_AUTH_TOKEN" ] && [ -n "$ANTHROPIC_BASE_URL" ]; then
  echo "[+] Claude Code auth: BYOK gateway (ANTHROPIC_AUTH_TOKEN + ANTHROPIC_BASE_URL)"
elif docker exec "$CONTAINER_NAME" test -f /home/paseo/.claude/.credentials.json 2>/dev/null; then
  echo "[+] Claude Code auth: stored claude /login credentials in paseo-home"
else
  echo "[!] no Claude Code auth configured - set CLAUDE_CODE_OAUTH_TOKEN (or ANTHROPIC_API_KEY) as a repo secret, or run claude /login inside the container" >&2
fi

# --- Health / network / tailscale ---
HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
echo "[i] health: ${HEALTH}"

NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")
echo "[i] network mode: ${NETMODE}"

if ip link show tailscale0 >/dev/null 2>&1; then
  echo "[+] tailscale0 visible"
else
  echo "[!] tailscale0 not present — tailnet access will not work" >&2
fi

MEM_USED=$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || echo "n/a")
echo "[i] memory: ${MEM_USED}"
echo "[i] hard caps: cpu=${CPU_LIMIT} mem=${MEM_LIMIT} mem+swap=${MEM_SWAP_LIMIT} pids=${PIDS_LIMIT}"

# --- Heartbeat ---
echo "[>] checking Paseo heartbeat"
if docker exec "$CONTAINER_NAME" sh -c 'command -v paseo >/dev/null 2>&1' 2>/dev/null; then
  if docker exec "$CONTAINER_NAME" sh -c 'paseo heartbeat ls 2>/dev/null | grep -q heartbeat' 2>/dev/null; then
    echo "[+] heartbeat exists"
  else
    docker exec -e HEARTBEAT_CRON="$HEARTBEAT_CRON" "$CONTAINER_NAME" sh -c '
      paseo heartbeat create \
        --cron "$HEARTBEAT_CRON" \
        --name heartbeat \
        "Check the current task state and continue with the next useful step."
    ' 2>/dev/null && echo "[+] heartbeat created" \
      || echo "[!] heartbeat creation failed — set it up manually inside an agent session"
  fi
fi

echo "[+] init done"
exit 0

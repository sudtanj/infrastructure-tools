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

PASEO_PORT="${PASEO_PORT:-6767}"

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

# --- Remove existing container ---
echo "[>] removing existing container"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
echo "[+] cleanup done"

# --- Ensure volumes ---
docker volume create paseo-home      >/dev/null
docker volume create paseo-workspace >/dev/null

# --- Wipe stale/corrupt Codex SQLite state ---
echo "[>] clearing stale Codex state"
docker run --rm -v paseo-home:/home/paseo alpine:latest sh -c '
  rm -rf /home/paseo/.codex/state \
         /home/paseo/.codex/*.sqlite \
         /home/paseo/.codex/*.sqlite-shm \
         /home/paseo/.codex/*.sqlite-wal 2>/dev/null || true
' >/dev/null 2>&1
echo "[+] state cleared"

# --- Seed Codex config into the persistent volume ---
# THIS is the block that was wrong before. sandbox_mode and approval_policy
# must be at the TOP level of config.toml — Codex does NOT read them from
# environment variables. Without these, Codex defaults to bwrap sandboxing
# and fails with "No permissions to create a new namespace".
echo "[>] seeding Codex config"
docker run --rm -v paseo-home:"$CODEX_CONFIG_DIR" alpine:latest sh -c "
  mkdir -p '$CODEX_CONFIG_DIR'
  cat > '$CODEX_CONFIG_FILE' <<'EOF'
# Managed by init-paseo-codex.sh — do not edit manually.

# Disable the bwrap sandbox entirely. Required because Docker's default
# seccomp profile blocks unshare(CLONE_NEWUSER), which bwrap needs.
sandbox_mode = \"danger-full-access\"
approval_policy = \"never\"

# Retry tuning for flaky upstream streams.
[model_providers.custom]
stream_max_retries = 100
request_max_retries = 100
stream_idle_timeout_ms = 300000
EOF
  chown -R 1000:1000 '/home/paseo'
" >/dev/null 2>&1
echo "[+] Codex config seeded"

# --- Start container ---
echo "[>] starting $CONTAINER_NAME"

docker run -d --name "$CONTAINER_NAME" --restart always \
  --user 1000:1000 \
  --network=host \
  --cpus 0.50 \
  --memory 384m \
  --memory-swap 768m \
  --memory-swappiness 60 \
  --pids-limit 384 \
  --dns 2a00:1098:2b::1 \
  --dns 2a01:4f9:c010:3f02::1 \
  --health-cmd "curl -fsS --max-time 3 http://127.0.0.1:${PASEO_PORT}/api/health || exit 1" \
  --health-interval=30s \
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
  -e NODE_OPTIONS="--max-old-space-size=256" \
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

# --- Verify sandbox_mode is actually disabled ---
echo "[>] verifying sandbox is disabled in config"
docker exec "$CONTAINER_NAME" sh -c '
  if grep -q "sandbox_mode = \"danger-full-access\"" /home/paseo/.codex/config.toml 2>/dev/null; then
    echo "[+] sandbox_mode = danger-full-access present"
  else
    echo "[x] sandbox_mode NOT set — Codex will try bwrap and fail" >&2
  fi
  if grep -q "approval_policy = \"never\"" /home/paseo/.codex/config.toml 2>/dev/null; then
    echo "[+] approval_policy = never present"
  else
    echo "[!] approval_policy missing" >&2
  fi
  if grep -q "stream_max_retries = 100" /home/paseo/.codex/config.toml 2>/dev/null; then
    echo "[+] retry config present"
  fi
' || true

# --- Verify .codex is writable and SQLite can init ---
docker exec "$CONTAINER_NAME" sh -c '
  touch /home/paseo/.codex/.writetest && rm -f /home/paseo/.codex/.writetest \
    && echo "[+] .codex writable" \
    || echo "[x] .codex NOT writable"
' || true

# --- Verify the effective sandbox mode as Codex sees it ---
echo "[>] checking effective sandbox mode"
if docker exec "$CONTAINER_NAME" sh -c 'command -v codex >/dev/null 2>&1' 2>/dev/null; then
  docker exec "$CONTAINER_NAME" codex --version 2>/dev/null || true
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

# --- Heartbeat ---
echo "[>] checking Paseo heartbeat"
if docker exec "$CONTAINER_NAME" sh -c 'command -v paseo >/dev/null 2>&1' 2>/dev/null; then
  if docker exec "$CONTAINER_NAME" sh -c 'paseo heartbeat ls 2>/dev/null | grep -q heartbeat' 2>/dev/null; then
    echo "[+] heartbeat exists"
  else
    docker exec "$CONTAINER_NAME" sh -c '
      paseo heartbeat create \
        --cron "*/20 * * * *" \
        --name heartbeat \
        "Check the current task state and continue with the next useful step."
    ' 2>/dev/null && echo "[+] heartbeat created" \
      || echo "[!] heartbeat creation failed — set it up manually inside an agent session"
  fi
fi

echo "[+] init done"
exit 0

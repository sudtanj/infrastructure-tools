#!/bin/bash
# bash-scripts/init-paseo-codex.sh
# Runs ON the VM via IAP SSH. Idempotent.
# Target: GCP free-tier e2-micro (384 MB allocation, 0.5 vCPU)
# Includes: Codex retry tuning + Paseo heartbeat for auto-continuation

set -euo pipefail

# All secrets arrive via env vars injected by the workflow
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

# --- Verify required secrets are present ---
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

# --- Ensure named volumes exist ---
docker volume create paseo-home      >/dev/null
docker volume create paseo-workspace >/dev/null

# --- Seed Codex retry config into the persistent volume ---
# Overwrites each run so retry settings stay consistent even if the
# volume was previously populated by a different version of this script.
echo "[>] seeding Codex retry config"
docker run --rm \
  -v paseo-home:"$CODEX_CONFIG_DIR" \
  alpine:latest sh -c "
    mkdir -p '$CODEX_CONFIG_DIR'
    cat > '$CODEX_CONFIG_FILE' <<'EOF'
# Managed by init-paseo-codex.sh — do not edit manually.
# High retry ceilings for flaky streams.
[model_providers.custom]
stream_max_retries = 100
request_max_retries = 100
stream_idle_timeout_ms = 300000
EOF
    chown -R 1000:1000 '$CODEX_CONFIG_DIR'
  " >/dev/null 2>&1
echo "[+] Codex retry config seeded"

# --- Start container ---
# Memory: hard cap 384m, swap headroom to 768m total (2x) for Node GC spikes.
# CPU: 0.5 vCPU (half of e2-micro's 2 vCPU burst, matches free-tier steady state).
# tmpfs sized to stay within the cgroup: 48m /tmp + 12m .codex = 60m ceiling.
# Codex retries are configured via the seeded config.toml in the volume.
echo "[>] starting $CONTAINER_NAME"

docker run -d --name "$CONTAINER_NAME" --restart always \
  --user 1000:1000 \
  --network=host \
  --cpus 0.50 \
  --memory 384m \
  --memory-swap 768m \
  --memory-swappiness 60 \
  --pids-limit 384 \
  --read-only \
  --tmpfs /tmp:size=48m,mode=1777 \
  --tmpfs /home/paseo/.codex:size=12m,uid=1000,gid=1000 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
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
  -e CODEX_SANDBOX_MODE="danger-full-access" \
  -e CODEX_APPROVAL_POLICY="never" \
  -e NODE_OPTIONS="--max-old-space-size=256" \
  "$IMAGE" \
  >/dev/null 2>&1

sleep 5

# --- Verify container is running ---
echo "[>] verifying container"
STATE=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "missing")
if [ "$STATE" != "running" ]; then
  echo "[x] container not running (state=${STATE})" >&2
  docker logs --tail 50 "$CONTAINER_NAME" >&2 || true
  echo "[>] last OOM events:" >&2
  dmesg 2>/dev/null | grep -i "killed process" | tail -5 >&2 || true
  exit 1
fi
echo "[+] container running"

# --- Verify health ---
HEALTH=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "unknown")
if [ "$HEALTH" = "unhealthy" ]; then
  echo "[x] container is unhealthy" >&2
  docker logs --tail 50 "$CONTAINER_NAME" >&2 || true
  exit 1
fi
echo "[+] health: ${HEALTH}"

# --- Verify network mode ---
NETMODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")
if [ "$NETMODE" != "host" ]; then
  echo "[x] network mode '${NETMODE}', expected 'host'" >&2
  exit 1
fi
echo "[+] network mode: host"

# --- Verify tailscale ---
if ip link show tailscale0 >/dev/null 2>&1; then
  echo "[+] tailscale0 visible"
else
  echo "[!] tailscale0 not present on host — tailnet access will not work" >&2
fi

# --- Verify Codex retry config landed inside the container ---
echo "[>] verifying Codex retry config inside container"
docker exec "$CONTAINER_NAME" sh -c "
  if grep -q 'stream_max_retries = 100' /home/paseo/.codex/config.toml 2>/dev/null; then
    echo '[+] retry config present'
  else
    echo '[!] retry config NOT found — Codex will use defaults' >&2
  fi
" || true

# --- Quick memory sanity check ---
MEM_USED=$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || echo "n/a")
echo "[i] current memory usage: ${MEM_USED}"

# --- Heartbeat: create once, survives container restarts ---
# The heartbeat lives on the Paseo daemon side (persisted via paseo-home volume),
# so it only needs to be created if one does not already exist.
# Requires PASEO_AGENT_ID, which Paseo sets automatically inside agent sessions.
echo "[>] checking Paseo heartbeat"
if docker exec "$CONTAINER_NAME" sh -c 'command -v paseo >/dev/null 2>&1' 2>/dev/null; then
  if docker exec "$CONTAINER_NAME" sh -c 'paseo heartbeat ls 2>/dev/null | grep -q heartbeat' 2>/dev/null; then
    echo "[+] heartbeat already exists"
  else
    echo "[>] creating heartbeat (every 20 minutes)"
    docker exec "$CONTAINER_NAME" sh -c '
      paseo heartbeat create \
        --cron "*/20 * * * *" \
        --name heartbeat \
        "Check the current task state and continue with the next useful step."
    ' 2>/dev/null && echo "[+] heartbeat created" \
      || echo "[!] heartbeat creation failed — can be set up manually inside an agent session"
  fi
else
  echo "[!] paseo CLI not found in container — skipping heartbeat setup" >&2
  echo "    Create it manually inside an agent session with:" >&2
  echo "    paseo heartbeat create --cron '*/20 * * * *' --name heartbeat 'Continue...'" >&2
fi

echo "[+] init done"
exit 0

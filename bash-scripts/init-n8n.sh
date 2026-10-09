#!/bin/bash
# bash-scripts/init-n8n.sh
# Idempotent deployment of n8n, tuned for the GCP free-tier e2-micro VM.
#
# Free-tier constraints this script is built around (see terraform_free_tier_gcp/):
#   - 1 non-preemptible e2-micro (1 GB RAM, 2 shared vCPU) in us-west1/us-central1/us-east1.
#   - 30 GB pd-standard boot disk. No extra disks, no managed instance groups, no autoscale.
#   - IPv6-only external networking. Inbound UI access is expected over Tailscale, not the public IP.
#   - ~1 GB/month free egress, so telemetry/template/version calls are switched off.
#
# Design notes:
#   - SQLite + regular execution mode. Postgres/Redis/queue mode is deliberately NOT used: on a
#     1 GB box two extra services would OOM the VM and are not needed at this scale.
#   - The credential encryption key is persisted outside the container and reused across runs.
#     Losing or regenerating it makes every stored n8n credential undecryptable.
#   - Nothing sensitive is echoed. This repo is public and the runner workflow echoes any line
#     starting with [*], [+], [>], [!] or [x] into a public Actions log. In particular the n8n
#     first-run "owner setup" URL embeds a bearer token, so it is never printed here.

set -euo pipefail

CONTAINER_NAME="${N8N_CONTAINER_NAME:-n8n}"
IMAGE="${N8N_IMAGE:-docker.n8n.io/n8nio/n8n:latest}"
VOLUME_NAME="${N8N_VOLUME_NAME:-n8n_data}"
DATA_DIR_IN_CONTAINER="/home/node/.n8n"
CONFIG_DIR="${N8N_CONFIG_DIR:-/etc/n8n}"
ENV_FILE="${CONFIG_DIR}/n8n.env"
BACKUP_SCRIPT="${N8N_BACKUP_SCRIPT:-/usr/local/bin/n8n-backup.sh}"
BACKUP_DIR="${N8N_BACKUP_DIR:-/var/backups/n8n}"
BACKUP_KEEP="${N8N_BACKUP_KEEP:-7}"
SYSTEMD_DIR="${N8N_SYSTEMD_DIR:-/etc/systemd/system}"

PORT="${N8N_PORT:-5678}"
CPU_LIMIT="${N8N_CPU_LIMIT:-0.50}"
MEMORY_LIMIT="${N8N_MEMORY_LIMIT:-256m}"
MAX_OLD_SPACE_MB="${N8N_MAX_OLD_SPACE_MB:-192}"
HEALTH_TIMEOUT="${N8N_HEALTH_TIMEOUT:-180}"
EXECUTIONS_TIMEOUT="${N8N_EXECUTIONS_TIMEOUT:-300}"
TIMEZONE="${N8N_TIMEZONE:-UTC}"
# Public URL users reach the UI on, e.g. http://100.x.y.z:5678. Used for editor links and webhooks.
PUBLIC_URL="${N8N_PUBLIC_URL:-}"
# Serve cookies over plain HTTP. Only safe because the UI is bound to loopback/Tailscale, never
# to a public interface. Set to true as soon as a TLS terminator is put in front of n8n.
SECURE_COOKIE="${N8N_SECURE_COOKIE:-false}"
BACKUP_ENABLED="${N8N_BACKUP_ENABLED:-true}"

# Readiness probe. Uses `node`, which is guaranteed to exist in the n8n image,
# rather than wget/curl: the image is Alpine-based on some versions and distroless
# on others, and a missing wget would fail every run. Exercised against 200/503/
# closed-port: exits 0 only on a 200 from /healthz/readiness.
READINESS_PROBE="require('http').get('http://127.0.0.1:5678/healthz/readiness',function(r){process.exit(r.statusCode===200?0:1)}).on('error',function(){process.exit(1)})"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
  DOCKER=(docker)
else
  SUDO=(sudo)
  DOCKER=(sudo docker)
fi

status "init n8n start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
ok "docker ready"

HOST_MEM_MB="$(awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || echo 0)"
DOCKER_FREE_MB="$(df -Pm /var/lib/docker 2>/dev/null | awk 'NR == 2 {print $4}' || echo 0)"
if [ "${DOCKER_FREE_MB:-0}" -gt 0 ]; then
  ok "host memory ${HOST_MEM_MB} MiB, docker disk free ${DOCKER_FREE_MB} MiB"
fi

# The VM also runs portainer and the self-hosted runner. Warn when the three
# container caps together cannot fit in RAM, since that shows up as random OOM
# kills rather than as a clean failure.
RESERVED_MB="${N8N_RESERVED_MEMORY_MB:-640}"
if [ "${HOST_MEM_MB:-0}" -gt 0 ]; then
  # Accept plain digits plus an optional m/g suffix (docker also allows k, not needed here).
  N8N_REQ_MB="$(printf '%s' "${MEMORY_LIMIT}" | tr '[:upper:]' '[:lower:]' | sed -e 's/m$//' -e 's/g$/\\*1024/' -e 's/[^0-9*]//g')"
  N8N_REQ_MB="$(( N8N_REQ_MB ))"
  if [ "$(( RESERVED_MB + N8N_REQ_MB ))" -gt "${HOST_MEM_MB}" ]; then
    warn "n8n cap ${MEMORY_LIMIT} plus ${RESERVED_MB} MiB reserved for portainer/runner exceeds host RAM ${HOST_MEM_MB} MiB"
    warn "lower N8N_MEMORY_LIMIT, or stop the GitHub runner container while n8n is busy"
  else
    ok "memory budget fits"
  fi
fi

if [ "${DOCKER_FREE_MB:-0}" -gt 0 ] && [ "${DOCKER_FREE_MB}" -lt 2048 ]; then
  warn "only ${DOCKER_FREE_MB} MiB free on the boot disk; the n8n image is roughly 700 MiB"
fi

# ---------------------------------------------------------------------------
# 2. Resolve the address to publish the UI on
# ---------------------------------------------------------------------------
step "resolving publish address"
BIND_ARGS=(-p "127.0.0.1:${PORT}:5678")

TS_IP=""
if command -v tailscale >/dev/null 2>&1; then
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
fi
if [ -z "${TS_IP}" ]; then
  # Kernel-mode Tailscale on COS keeps its binary out of PATH (see cloud-init.yaml.tftpl).
  for candidate in /var/lib/docker/tailscale-bin/tailscale /usr/bin/tailscale /usr/local/bin/tailscale; do
    if [ -x "${candidate}" ]; then
      TS_IP="$("${candidate}" ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
      [ -n "${TS_IP}" ] && break
    fi
  done
fi
if [ -z "${TS_IP}" ]; then
  TS_IP="$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
fi

if [ -n "${TS_IP}" ]; then
  BIND_ARGS+=(-p "${TS_IP}:${PORT}:5678")
  ok "publishing on 127.0.0.1 and tailscale ${TS_IP}"
  if [ -z "${PUBLIC_URL}" ]; then
    PUBLIC_URL="http://${TS_IP}:${PORT}"
    ok "public url derived as ${PUBLIC_URL}"
  fi
else
  warn "no tailscale address found; UI reachable on 127.0.0.1:${PORT} only (tunnel to it)"
  [ -z "${PUBLIC_URL}" ] && PUBLIC_URL="http://127.0.0.1:${PORT}"
fi

# ---------------------------------------------------------------------------
# 3. Persistent config: reuse the encryption key, never regenerate it
# ---------------------------------------------------------------------------
step "preparing ${CONFIG_DIR}"
"${SUDO[@]}" mkdir -p "${CONFIG_DIR}"
"${SUDO[@]}" chmod 700 "${CONFIG_DIR}"

EXISTING_KEY=""
if [ -f "${ENV_FILE}" ]; then
  EXISTING_KEY="$(sed -n 's/^N8N_ENCRYPTION_KEY=//p' "${ENV_FILE}" | head -n1)"
  ok "existing config found"
fi

# Precedence: explicit N8N_ENCRYPTION_KEY env (workflow secret) > key already on disk > new.
if [ -n "${N8N_ENCRYPTION_KEY:-}" ]; then
  ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}"
  if [ -n "${EXISTING_KEY}" ] && [ "${EXISTING_KEY}" != "${ENCRYPTION_KEY}" ]; then
    fail "N8N_ENCRYPTION_KEY differs from the key in ${ENV_FILE}; existing stored credentials would become unreadable. Restore the old key or wipe the ${VOLUME_NAME} volume deliberately."
  fi
  ok "encryption key taken from environment"
elif [ -n "${EXISTING_KEY}" ]; then
  ENCRYPTION_KEY="${EXISTING_KEY}"
  ok "encryption key preserved from ${ENV_FILE}"
else
  ENCRYPTION_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  ok "generated a new encryption key, stored in ${ENV_FILE}"
fi

# The file is rewritten on every run so tuning changes take effect, but the key
# value itself is carried over. Written 0600 because it holds the encryption key.
umask 077
"${SUDO[@]}" tee "${ENV_FILE}" >/dev/null <<EOF
# Managed by bash-scripts/init-n8n.sh - do not edit by hand.
# N8N_ENCRYPTION_KEY must stay stable: changing it makes stored credentials unreadable.
N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}
N8N_HOST=${TS_IP:-localhost}
N8N_PORT=5678
N8N_PROTOCOL=http
N8N_LISTEN_ADDRESS=0.0.0.0
N8N_SECURE_COOKIE=${SECURE_COOKIE}
N8N_EDITOR_BASE_URL=${PUBLIC_URL}
N8N_SAMESITE_COOKIE=lax
WEBHOOK_URL=${PUBLIC_URL}/
TZ=${TIMEZONE}
GENERIC_TIMEZONE=${TIMEZONE}

# --- SQLite: no second database process on a 1 GB VM ---
DB_TYPE=sqlite
DB_SQLITE_POOL_SIZE=2

# --- Execution footprint: keep the SQLite file and CPU work small ---
EXECUTIONS_MODE=regular
EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
EXECUTIONS_DATA_SAVE_ON_ERROR=all
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=72
EXECUTIONS_TIMEOUT=${EXECUTIONS_TIMEOUT}

# --- Binary data on disk, never in RAM ---
N8N_DEFAULT_BINARY_DATA_MODE=filesystem

# --- Egress: every call below leaves the free 1 GB/month allowance ---
N8N_DIAGNOSTICS_ENABLED=false
N8N_VERSION_NOTIFICATIONS_ENABLED=false
N8N_TEMPLATES_ENABLED=false
N8N_HIRING_BANNER_ENABLED=false

# --- Keep V8 inside the container memory cap so the OOM killer stays away ---
NODE_OPTIONS=--max-old-space-size=${MAX_OLD_SPACE_MB}
EOF
"${SUDO[@]}" chmod 600 "${ENV_FILE}"
ok "config written to ${ENV_FILE} (mode 600, value not logged)"

# ---------------------------------------------------------------------------
# 4. Persistent data volume
# ---------------------------------------------------------------------------
step "ensuring ${VOLUME_NAME} volume exists"
"${DOCKER[@]}" volume create "${VOLUME_NAME}" >/dev/null
ok "volume ready"

# ---------------------------------------------------------------------------
# 5. Image
# ---------------------------------------------------------------------------
step "pulling ${IMAGE}"
# The VM is IPv6-only and some registries (docker.n8n.io, Docker Hub) are flaky or lack IPv6,
# so retry and then fall back to mirrors. Pull output carries no secrets, so the last lines are
# shown on failure to make the cause visible in the log.
PULL_CANDIDATES=("${IMAGE}")
if [ -z "${N8N_IMAGE:-}" ]; then
  PULL_CANDIDATES+=("ghcr.io/n8n-io/n8n:latest" "docker.io/n8nio/n8n:latest")
fi

PULLED=""
for candidate in "${PULL_CANDIDATES[@]}"; do
  for attempt in 1 2 3; do
    if PULL_OUT="$("${DOCKER[@]}" pull "${candidate}" 2>&1)"; then
      PULLED="${candidate}"
      break 2
    fi
    warn "pull of ${candidate} failed (attempt ${attempt}/3)"
    printf '%s\n' "${PULL_OUT}" | tail -n 5 >&2
    [ "${attempt}" -lt 3 ] && sleep $(( attempt * 5 ))
  done
done
[ -n "${PULLED}" ] || fail "failed to pull ${IMAGE} (and mirrors); check IPv6/DNS access to the registry"
IMAGE="${PULLED}"
ok "image present (${IMAGE})"

step "pruning dangling images to protect the 30 GB boot disk"
PRUNED="$("${DOCKER[@]}" image prune -f 2>/dev/null | tail -n1 || true)"
ok "${PRUNED:-nothing to prune}"

# ---------------------------------------------------------------------------
# 6. Replace the container (data survives in the volume)
# ---------------------------------------------------------------------------
step "removing existing ${CONTAINER_NAME} container"
if "${DOCKER[@]}" ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  "${DOCKER[@]}" stop --time 30 "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  "${DOCKER[@]}" rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  ok "existing container removed"
else
  ok "no existing container found"
fi

step "starting ${CONTAINER_NAME}"
"${DOCKER[@]}" run -d \
  --name "${CONTAINER_NAME}" \
  --restart unless-stopped \
  --init \
  "${BIND_ARGS[@]}" \
  --env-file "${ENV_FILE}" \
  --cpus "${CPU_LIMIT}" \
  --memory "${MEMORY_LIMIT}" \
  --memory-swap "${MEMORY_LIMIT}" \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  --health-cmd "node -e \"${READINESS_PROBE}\"" \
  --health-interval 30s \
  --health-timeout 10s \
  --health-retries 3 \
  --health-start-period 90s \
  -v "${VOLUME_NAME}:${DATA_DIR_IN_CONTAINER}" \
  "${IMAGE}" \
  >/dev/null 2>&1 || fail "failed to start ${CONTAINER_NAME} container"

# ---------------------------------------------------------------------------
# 7. Verify readiness
# ---------------------------------------------------------------------------
step "waiting for n8n to become ready"
DEADLINE=$(( $(date +%s) + HEALTH_TIMEOUT ))
READY=0
while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo missing)"
  if [ "${STATE}" != "running" ]; then
    warn "n8n state: ${STATE}"
    "${DOCKER[@]}" logs --tail 30 "${CONTAINER_NAME}" 2>&1 | \
      sed -E 's#(https?://[^[:space:]]+/rest/owner/setup/)[^[:space:]]+#\1<redacted>#g' >&2 || true
    fail "n8n container not running"
  fi
  if "${DOCKER[@]}" exec "${CONTAINER_NAME}" \
      node -e "${READINESS_PROBE}" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

if [ "${READY}" -ne 1 ]; then
  warn "n8n did not pass /healthz/readiness within ${HEALTH_TIMEOUT}s"
  "${DOCKER[@]}" logs --tail 30 "${CONTAINER_NAME}" 2>&1 | \
    sed -E 's#(https?://[^[:space:]]+/rest/owner/setup/)[^[:space:]]+#\1<redacted>#g' >&2 || true
  fail "n8n health check failed"
fi
ok "n8n is up and ready"

# ---------------------------------------------------------------------------
# 8. Daily local backup of the workflow database
# ---------------------------------------------------------------------------
if [ "${BACKUP_ENABLED}" = "true" ]; then
  step "installing daily backup (${BACKUP_KEEP} local copies retained)"
  "${SUDO[@]}" mkdir -p "${BACKUP_DIR}" "${SYSTEMD_DIR}" "$(dirname "${BACKUP_SCRIPT}")"
  "${SUDO[@]}" tee "${BACKUP_SCRIPT}" >/dev/null <<BACKUP_EOF
#!/bin/bash
# Managed by bash-scripts/init-n8n.sh - do not edit by hand.
# Snapshots the n8n data volume to local disk. The free-tier boot disk is the only
# copy, so this protects against a bad upgrade, not against losing the disk itself.
set -euo pipefail
SRC="\$(docker volume inspect ${VOLUME_NAME} --format '{{.Mountpoint}}')"
STAMP="\$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${BACKUP_DIR}/n8n-\${STAMP}.tar.gz"
tar -czf "\${OUT}.tmp" -C "\${SRC}" . && mv "\${OUT}.tmp" "\${OUT}"
ls -1t ${BACKUP_DIR}/n8n-*.tar.gz 2>/dev/null | tail -n +$(( ${BACKUP_KEEP} + 1 )) | xargs -r rm -f
BACKUP_EOF
  "${SUDO[@]}" chmod 700 "${BACKUP_SCRIPT}"

  "${SUDO[@]}" tee "${SYSTEMD_DIR}/n8n-backup.service" >/dev/null <<SERVICE_EOF
[Unit]
Description=Back up n8n data volume
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
ExecStart=${BACKUP_SCRIPT}
SERVICE_EOF

  "${SUDO[@]}" tee "${SYSTEMD_DIR}/n8n-backup.timer" >/dev/null <<TIMER_EOF
[Unit]
Description=Daily n8n data volume backup

[Timer]
OnCalendar=*-*-* 03:30:00 UTC
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
TIMER_EOF

  "${SUDO[@]}" systemctl daemon-reload >/dev/null 2>&1 || true
  "${SUDO[@]}" systemctl enable --now n8n-backup.timer >/dev/null 2>&1 \
    && ok "backup timer enabled" \
    || warn "could not enable n8n-backup.timer (systemd unavailable); run ${BACKUP_SCRIPT} manually"
else
  step "backup disabled (N8N_BACKUP_ENABLED=false), skipping"
fi

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------
HEALTH="$("${DOCKER[@]}" inspect -f '{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo unknown)"
ok "n8n is up and running (health: ${HEALTH})"
ok "ui: ${PUBLIC_URL}"
ok "caps: ${CPU_LIMIT} cpu, ${MEMORY_LIMIT} memory, execution timeout ${EXECUTIONS_TIMEOUT}s"
status "first run only: open the UI in a browser and create the owner account"
status "the owner-setup URL embeds a bearer token and is deliberately not logged; read it yourself with: docker logs ${CONTAINER_NAME} 2>&1 | grep -m1 '/rest/owner/setup/'"
ok "config: ${ENV_FILE}, data: volume ${VOLUME_NAME}"

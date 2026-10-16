#!/bin/bash
# bash-scripts/init-mini-router.sh
# Idempotent deploy/update of mini-router (sudtanj/mini-router, see builder-tools/mini-router/)
# on a small board, tuned for the Orange Pi Zero 3 (4x A53, 1 GB RAM, SD card):
#   - published only on 127.0.0.1 by default (not on the LAN); MINI_ROUTER_BIND opens it deliberately
#   - read-only rootfs, all caps dropped, hard RAM cap without swap, low CPU weight
#   - 1 tokio worker, warn-level logs capped at 1 MB
#   - with Turso configured: TURSO_ONLY by default, so the database lives in RAM and
#     nothing is written to the SD card (/data is a 4 MB tmpfs)
#
# Security model (this repo and its Actions logs are public): secret values are never
# printed and never put on a command line; they reach docker through a 0600 env file
# that is deleted right after `docker run`.
#
# Env (all optional):
#   MINI_ROUTER_TURSO_URL         libsql://<db>-<org>.turso.io
#   MINI_ROUTER_TURSO_TOKEN       Turso auth token
#   MINI_ROUTER_TURSO_ONLY        1 | 0, default 1 when both Turso values are set, else 0
#   MINI_ROUTER_TURSO_SYNC_SECS   push interval, default 30
#   MINI_ROUTER_INITIAL_PASSWORD  dashboard password until one is saved (default 123456)
#   MINI_ROUTER_JWT_SECRET        fixed dashboard session secret
#   MINI_ROUTER_REQUIRE_API_KEY   true | false, default false
#   MINI_ROUTER_BIND              host address to publish on, default 127.0.0.1 (loopback only).
#                                 Use the Tailscale IP (tailscale ip -4) or a LAN IP to reach it remotely;
#                                 0.0.0.0 exposes it on every interface and is refused unless
#                                 MINI_ROUTER_ALLOW_ANY=1.
#   MINI_ROUTER_PORT              default 20128
#   MINI_ROUTER_IMAGE             default sudtanj/mini-router:latest
#   MINI_ROUTER_CPU_LIMIT         default 1.0 (of 4 cores)
#   MINI_ROUTER_MEMORY_LIMIT      default 96m (swap disabled)

set -euo pipefail

CONTAINER_NAME="mini-router"
VOLUME_NAME="mini-router-data"
IMAGE="${MINI_ROUTER_IMAGE:-sudtanj/mini-router:latest}"
PORT="${MINI_ROUTER_PORT:-20128}"
BIND="${MINI_ROUTER_BIND:-127.0.0.1}"
TURSO_URL="${MINI_ROUTER_TURSO_URL:-}"
TURSO_TOKEN="${MINI_ROUTER_TURSO_TOKEN:-}"
if [ -n "$TURSO_URL" ] && [ -n "$TURSO_TOKEN" ]; then DEF_ONLY=1; else DEF_ONLY=0; fi
TURSO_ONLY="${MINI_ROUTER_TURSO_ONLY:-$DEF_ONLY}"
TURSO_SYNC_SECS="${MINI_ROUTER_TURSO_SYNC_SECS:-30}"
INITIAL_PASSWORD="${MINI_ROUTER_INITIAL_PASSWORD:-}"
JWT_SECRET="${MINI_ROUTER_JWT_SECRET:-}"
REQUIRE_API_KEY="${MINI_ROUTER_REQUIRE_API_KEY:-false}"
CPU_LIMIT="${MINI_ROUTER_CPU_LIMIT:-1.0}"
MEMORY_LIMIT="${MINI_ROUTER_MEMORY_LIMIT:-96m}"
CONFIG_REV="2"   # bump when the docker run flags below change

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
debug()  { [ "${INIT_DEBUG:-0}" = "1" ] && printf '%s\n' "[d] $*" || true; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }
present() { if [ -n "${1:-}" ]; then echo set; else echo unset; fi; }

if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

# The board also runs other things: keep this script itself out of their way.
renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

status "init mini-router start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) fail "unsupported arch $(uname -m); the image is built for amd64 and arm64 only" ;;
esac
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || fail "MINI_ROUTER_PORT must be a number"
[[ "$BIND" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "MINI_ROUTER_BIND must be an IPv4 address"
if [ "$BIND" = "0.0.0.0" ] && [ "${MINI_ROUTER_ALLOW_ANY:-0}" != "1" ]; then
  fail "MINI_ROUTER_BIND=0.0.0.0 exposes the router on every interface; set MINI_ROUTER_ALLOW_ANY=1 if that is intended"
fi
case "$TURSO_ONLY" in 0|1) ;; *) fail "MINI_ROUTER_TURSO_ONLY must be 0 or 1" ;; esac
if [ "$TURSO_ONLY" = "1" ] && { [ -z "$TURSO_URL" ] || [ -z "$TURSO_TOKEN" ]; }; then
  fail "MINI_ROUTER_TURSO_ONLY=1 needs MINI_ROUTER_TURSO_URL and MINI_ROUTER_TURSO_TOKEN"
fi
if [ -z "$INITIAL_PASSWORD" ]; then
  warn "MINI_ROUTER_INITIAL_PASSWORD unset: dashboard password is the 9router default until changed"
fi
if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :${PORT}" 2>/dev/null | grep -q . \
   && ! "${DOCKER[@]}" inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  fail "port ${PORT} is already in use on the host"
fi
MEM_AVAIL="$(free -m | awk '/^Mem:/{print $7}')"
debug "turso: url=$(present "$TURSO_URL") token=$(present "$TURSO_TOKEN") only=${TURSO_ONLY} | password=$(present "$INITIAL_PASSWORD") jwt=$(present "$JWT_SECRET") | mem_avail=${MEM_AVAIL}MB"
ok "docker ready"

# ---------------------------------------------------------------------------
# 2. Image
# ---------------------------------------------------------------------------
OLD_IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
step "pulling ${IMAGE}"
PULLED=0
for attempt in 1 2 3; do
  if "${DOCKER[@]}" pull -q "$IMAGE" >/dev/null 2>&1; then PULLED=1; break; fi
  warn "pull failed (attempt ${attempt}/3)"
  [ "$attempt" -lt 3 ] && sleep $(( attempt * 5 ))
done
if [ "$PULLED" != "1" ]; then
  [ -n "$OLD_IMAGE_ID" ] || fail "failed to pull ${IMAGE}"
  warn "pull failed, keeping the local image"
fi
IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE")"
ok "image ready"

# ---------------------------------------------------------------------------
# 3. Skip the restart when nothing changed
# ---------------------------------------------------------------------------
# Hash of every setting (secrets included, never printed), stored as a label.
WANT_SUM="$(printf '%s\n' "$IMAGE_ID" "$PORT" "$BIND" "$TURSO_URL" "$TURSO_TOKEN" "$TURSO_ONLY" "$TURSO_SYNC_SECS" \
  "$INITIAL_PASSWORD" "$JWT_SECRET" "$REQUIRE_API_KEY" "$CPU_LIMIT" "$MEMORY_LIMIT" "$CONFIG_REV" \
  | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "mini-router.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"

if [ "$WANT_SUM" = "$HAVE_SUM" ] && [ "$STATE" = "running" ]; then
  ok "${CONTAINER_NAME} already running with the current image and settings"
else
  debug "recreate reason: state=${STATE}, config $([ "$WANT_SUM" = "$HAVE_SUM" ] && echo same || echo changed)"

  # Storage: RAM only with TURSO_ONLY, else a named volume for the SQLite file.
  if [ "$TURSO_ONLY" = "1" ]; then
    DATA_OPTS=(--tmpfs "/data:rw,noexec,nosuid,nodev,size=4m,uid=65532,gid=65532,mode=0700")
    MEDIA="tmpfs (Turso is the durable copy)"
  else
    DATA_OPTS=(-v "${VOLUME_NAME}:/data")
    MEDIA="volume ${VOLUME_NAME}"
  fi
  # API keys embed the machine id, like 9router: keep it stable across recreations.
  MID_OPTS=()
  [ -r /etc/machine-id ] && MID_OPTS=(-v /etc/machine-id:/etc/machine-id:ro)

  ENV_FILE="$(umask 077; mktemp)"
  trap 'rm -f "$ENV_FILE"' EXIT
  {
    echo "PORT=${PORT}"
    echo "HOSTNAME=0.0.0.0"
    echo "MINI_ROUTER_WORKERS=1"
    echo "LOG_LEVEL=warn"
    echo "REQUIRE_API_KEY=${REQUIRE_API_KEY}"
    # Claude Code / Codex requests rarely exceed a few MB; bound what one request can pin.
    echo "MAX_BODY_BYTES=16777216"
    [ -n "$INITIAL_PASSWORD" ] && echo "INITIAL_PASSWORD=${INITIAL_PASSWORD}"
    [ -n "$JWT_SECRET" ] && echo "JWT_SECRET=${JWT_SECRET}"
    if [ -n "$TURSO_URL" ] && [ -n "$TURSO_TOKEN" ]; then
      echo "TURSO_DATABASE_URL=${TURSO_URL}"
      echo "TURSO_AUTH_TOKEN=${TURSO_TOKEN}"
      echo "TURSO_SYNC_SECS=${TURSO_SYNC_SECS}"
      echo "TURSO_ONLY=${TURSO_ONLY}"
    fi
    # Keep env-file parsing literal: values are written raw, one per line.
  } > "$ENV_FILE"

  step "removing existing ${CONTAINER_NAME} container"
  # SIGTERM first: with Turso, mini-router does a final push on clean shutdown.
  "${DOCKER[@]}" stop -t 15 "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  ok "old container gone"

  step "starting ${CONTAINER_NAME} (data: ${MEDIA})"
  "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${BIND}:${PORT}:${PORT}" \
    --env-file "$ENV_FILE" \
    --label "mini-router.config=${WANT_SUM}" \
    "${DATA_OPTS[@]}" "${MID_OPTS[@]}" \
    --read-only \
    --cpus "$CPU_LIMIT" --cpu-shares 512 \
    --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" \
    --oom-score-adj 300 \
    --pids-limit 64 \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
    "$IMAGE" >/dev/null || fail "failed to start ${CONTAINER_NAME}"
  rm -f "$ENV_FILE"
fi
unset TURSO_TOKEN INITIAL_PASSWORD JWT_SECRET

# Free SD space: drop the previous image once nothing uses it.
if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$IMAGE_ID" ]; then
  "${DOCKER[@]}" rmi "$OLD_IMAGE_ID" >/dev/null 2>&1 && debug "removed previous image" || true
fi

# ---------------------------------------------------------------------------
# 4. Verify: running, not restart-looping, and answering HTTP
# ---------------------------------------------------------------------------
show_logs() {
  "${DOCKER[@]}" logs --tail "$1" "$CONTAINER_NAME" 2>&1 \
    | sed -E 's/(sk-|libsql:\/\/)[A-Za-z0-9._-]+/\1***/g; s/^/'"$2"' /' || true
}

step "checking ${CONTAINER_NAME} stays up"
RESTARTS_BEFORE="$("${DOCKER[@]}" inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
sleep 10
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
RESTARTS="$("${DOCKER[@]}" inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
OOM="$("${DOCKER[@]}" inspect -f '{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
if [ "$STATE" != "running" ] || [ "${RESTARTS:-0}" -gt "${RESTARTS_BEFORE:-0}" ]; then
  warn "state: ${STATE}, restarts during check: $(( ${RESTARTS:-0} - ${RESTARTS_BEFORE:-0} ))"
  show_logs 20 '[!]  ' >&2
  [ "$OOM" = "true" ] && fail "${CONTAINER_NAME} hit the ${MEMORY_LIMIT} memory cap; raise MINI_ROUTER_MEMORY_LIMIT"
  fail "${CONTAINER_NAME} is not staying up"
fi

PROBE=""
PROBE_HOST="$BIND"; [ "$BIND" = "0.0.0.0" ] && PROBE_HOST=127.0.0.1
if command -v curl >/dev/null 2>&1; then
  PROBE="$(curl -fsS -m 5 "http://${PROBE_HOST}:${PORT}/api/info" 2>/dev/null || true)"
elif command -v wget >/dev/null 2>&1; then
  PROBE="$(wget -qO- -T 5 "http://${PROBE_HOST}:${PORT}/api/info" 2>/dev/null || true)"
fi
if [ -n "$PROBE" ]; then
  ok "HTTP answering on port ${PORT}"
elif command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
  show_logs 20 '[!]  ' >&2
  fail "no HTTP answer on ${PROBE_HOST}:${PORT}/api/info"
else
  warn "no curl/wget on the host, skipped the HTTP probe"
fi
if [ "$TURSO_URL" != "" ] && "${DOCKER[@]}" logs "$CONTAINER_NAME" 2>&1 | grep -q "turso: not connected"; then
  warn "Turso not reachable yet (pushes paused until it is); check the URL/token"
fi
[ "${INIT_DEBUG:-0}" = "1" ] && show_logs 10 '[d]  '

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE}"
echo "[*] published: ${BIND}:${PORT} (container port ${PORT}) | dashboard: /dashboard | api: /v1"
echo "[*] storage: $([ "$TURSO_ONLY" = "1" ] && echo "RAM + Turso (no SD writes)" || echo "volume ${VOLUME_NAME}")"
echo "[*] limits: cpu ${CPU_LIMIT}, memory ${MEMORY_LIMIT} (no swap), pids 64"
echo "[*] memory: ${MEM:-unknown}"
ok "init mini-router done"

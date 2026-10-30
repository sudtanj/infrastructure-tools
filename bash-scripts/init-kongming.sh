#!/bin/bash
# bash-scripts/init-kongming.sh
# Idempotent deploy/update of kongming (sudtanj/kongming, see builder-tools/kongming/)
# on a small board, tuned for the Orange Pi Zero 3 (4x A53, 1 GB RAM, SD card):
#   - published on 0.0.0.0 (reachable from outside the board) by default, which needs
#     KONGMING_PASSWORD; KONGMING_BIND=127.0.0.1 keeps it on the board only
#   - read-only rootfs, no volume at all (state is on Turso), all caps dropped,
#     hard RAM cap without swap, low CPU weight
#   - 1 tokio worker, logs capped at 1 MB
#   - the agents' `shell` tool (bundled BusyBox) is read-only: no working tmpfs, and
#     kongming refuses file writes from it (Landlock where the kernel has it), and the container
#     has no writable mount at all (no /tmp tmpfs, --ipc none: no /dev/shm); it is for the
#     network and commands such as cdp (skills give it the addresses it needs)
#
# Security model (this repo and its Actions logs are public): secret values are never
# printed and never put on a command line; they reach docker through a 0600 env file
# that is deleted right after `docker run`.
#
# Env:
#   KONGMING_TURSO_DATABASE_URL   libsql://<db>-<org>.turso.io           (required)
#   KONGMING_TURSO_AUTH_TOKEN     Turso auth token                       (required)
#                                 (the older KONGMING_TURSO_URL / KONGMING_TURSO_TOKEN still work)
#   KONGMING_PASSWORD             web UI password                        (required unless BIND is 127.0.0.1)
#   KONGMING_SECRET               cookie signing secret                  (recommended)
#   KONGMING_PUBLIC_URL           optional public HTTPS URL; leave empty behind a firewall
#                                 (MCP OAuth then uses the localhost redirect + paste flow and
#                                 Telegram uses long polling; with it, a Telegram webhook)
#   The LLM provider and Telegram are set up later in the dashboard (stored on Turso).
#   KONGMING_BIND                 host address to publish on, default 0.0.0.0 (every interface)
#   KONGMING_PORT                 host port, default 18800 (container listens on 18800)
#   KONGMING_IMAGE                default sudtanj/kongming:latest
#   KONGMING_CPU_LIMIT            default 1.0
#   KONGMING_MEMORY_LIMIT         default 96m (swap disabled)
#   KONGMING_NETWORK              default "host": kongming shares the board's network, so the agents' shell
#                                 reaches what the board reaches (loopback, LAN, tailnet); it listens on
#                                 BIND port 18800 (PORT is ignored). "bridge" publishes BIND:PORT instead
# The Orange Pi runner fills these from the KONGMING_* repo secrets (same suffix).

set -euo pipefail

CONTAINER_NAME="kongming"
IMAGE="${KONGMING_IMAGE:-sudtanj/kongming:latest}"
PORT="${KONGMING_PORT:-18800}"
CPORT=18800
BIND="${KONGMING_BIND:-0.0.0.0}"
TURSO_URL="${KONGMING_TURSO_DATABASE_URL:-${KONGMING_TURSO_URL:-}}"
TURSO_TOKEN="${KONGMING_TURSO_AUTH_TOKEN:-${KONGMING_TURSO_TOKEN:-}}"
PASSWORD="${KONGMING_PASSWORD:-}"
SECRET="${KONGMING_SECRET:-}"
PUBLIC_URL="${KONGMING_PUBLIC_URL:-}"
CPU_LIMIT="${KONGMING_CPU_LIMIT:-1.0}"
MEMORY_LIMIT="${KONGMING_MEMORY_LIMIT:-96m}"
NETWORK="${KONGMING_NETWORK:-host}"
CONFIG_REV="8"   # bump when the docker run flags below change

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
debug()  { [ "${INIT_DEBUG:-0}" = "1" ] && printf '%s\n' "[d] $*" || true; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }
present() { if [ -n "${1:-}" ]; then echo set; else echo unset; fi; }

if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

status "init kongming start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) fail "unsupported arch $(uname -m); the image is built for amd64 and arm64 only" ;;
esac
[ -n "$TURSO_URL" ] && [ -n "$TURSO_TOKEN" ] || fail "KONGMING_TURSO_DATABASE_URL and KONGMING_TURSO_AUTH_TOKEN are required (kongming keeps no local data)"
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || fail "KONGMING_PORT must be a number"
[[ "$BIND" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "KONGMING_BIND must be an IPv4 address"
case "$NETWORK" in bridge|host) ;; *) fail "KONGMING_NETWORK must be bridge or host" ;; esac
if [ -z "$PASSWORD" ]; then
  [ "$BIND" = "127.0.0.1" ] || fail "KONGMING_PASSWORD is required when kongming is published on ${BIND} (anyone who reaches it could use your agents and keys); set it, or KONGMING_BIND=127.0.0.1"
  warn "KONGMING_PASSWORD unset: the web UI has no login (loopback only)"
fi
[ -z "$SECRET" ] && warn "KONGMING_SECRET unset: UI logins reset on every restart"
if [ "$NETWORK" = "bridge" ] && command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :${PORT}" 2>/dev/null | grep -q . \
   && ! "${DOCKER[@]}" inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  fail "port ${PORT} is already in use on the host"
fi
MEM_AVAIL="$(free -m | awk '/^Mem:/{print $7}')"
debug "turso: url=$(present "$TURSO_URL") token=$(present "$TURSO_TOKEN") | password=$(present "$PASSWORD") secret=$(present "$SECRET") | network=${NETWORK} | mem_avail=${MEM_AVAIL}MB"
ok "docker ready"

# An earlier version kept kongming on its own bridge with a firewall in front of the
# tailnet; it now shares the host network, so remove what that version installed.
if [ -e /usr/local/sbin/kongming-egress ] || [ -e /etc/systemd/system/kongming-egress.service ]; then
  step "removing the old tailnet block"
  if [ "$(id -u)" -eq 0 ]; then ROOT=(); else ROOT=(sudo); fi
  ${ROOT[@]+"${ROOT[@]}"} systemctl disable -q kongming-egress.service >/dev/null 2>&1 || true
  ${ROOT[@]+"${ROOT[@]}"} rm -f /etc/systemd/system/kongming-egress.service /usr/local/sbin/kongming-egress || true
  ${ROOT[@]+"${ROOT[@]}"} systemctl daemon-reload >/dev/null 2>&1 || true
  while ${ROOT[@]+"${ROOT[@]}"} iptables -w -t mangle -D PREROUTING -i br-kongming -j KONGMING-TAILNET 2>/dev/null; do :; done
  ${ROOT[@]+"${ROOT[@]}"} iptables -w -t mangle -F KONGMING-TAILNET 2>/dev/null || true
  ${ROOT[@]+"${ROOT[@]}"} iptables -w -t mangle -X KONGMING-TAILNET 2>/dev/null || true
  ok "old tailnet block removed"
fi

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
WANT_SUM="$(printf '%s\n' "$IMAGE_ID" "$PORT" "$BIND" "$NETWORK" "$TURSO_URL" "$TURSO_TOKEN" "$PASSWORD" "$SECRET" "$PUBLIC_URL" \
  "$CPU_LIMIT" "$MEMORY_LIMIT" "$CONFIG_REV" \
  | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "kongming.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"

if [ "$WANT_SUM" = "$HAVE_SUM" ] && [ "$STATE" = "running" ]; then
  ok "${CONTAINER_NAME} already running with the current image and settings"
else
  debug "recreate reason: state=${STATE}, config $([ "$WANT_SUM" = "$HAVE_SUM" ] && echo same || echo changed)"

  ENV_FILE="$(umask 077; mktemp)"
  trap 'rm -f "$ENV_FILE"' EXIT
  {
    echo "PORT=${CPORT}"
    echo "KONGMING_HOST=$([ "$NETWORK" = "host" ] && echo "$BIND" || echo 0.0.0.0)"
    echo "KONGMING_WORKERS=1"
    echo "LOG_LEVEL=info"
    echo "KONGMING_TURSO_DATABASE_URL=${TURSO_URL}"
    echo "KONGMING_TURSO_AUTH_TOKEN=${TURSO_TOKEN}"
    [ -n "$PASSWORD" ] && echo "KONGMING_PASSWORD=${PASSWORD}"
    [ -n "$SECRET" ] && echo "KONGMING_SECRET=${SECRET}"
    [ -n "$PUBLIC_URL" ] && echo "KONGMING_PUBLIC_URL=${PUBLIC_URL}"
  } > "$ENV_FILE"

  NET_OPTS=()
  if [ "$NETWORK" = "host" ]; then
    NET_OPTS=(--network host)
  else
    NET_OPTS=(-p "${BIND}:${PORT}:${CPORT}")
  fi

  step "removing existing ${CONTAINER_NAME} container"
  "${DOCKER[@]}" stop -t 10 "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  ok "old container gone"

  step "starting ${CONTAINER_NAME} (no volume: state lives on Turso)"
  "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    "${NET_OPTS[@]}" \
    --env-file "$ENV_FILE" \
    --label "kongming.config=${WANT_SUM}" \
    --read-only \
    --ipc none \
    --cpus "$CPU_LIMIT" --cpu-shares 512 \
    --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" \
    --oom-score-adj 300 \
    --pids-limit 64 \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
    "$IMAGE" >/dev/null || fail "failed to start ${CONTAINER_NAME}"
  rm -f "$ENV_FILE"
fi
unset TURSO_TOKEN PASSWORD SECRET
"${DOCKER[@]}" network inspect kongming >/dev/null 2>&1 && { "${DOCKER[@]}" network rm kongming >/dev/null 2>&1 || true; }

if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$IMAGE_ID" ]; then
  "${DOCKER[@]}" rmi "$OLD_IMAGE_ID" >/dev/null 2>&1 && debug "removed previous image" || true
fi

# ---------------------------------------------------------------------------
# 4. Verify: running, not restart-looping, and answering HTTP
# ---------------------------------------------------------------------------
show_logs() {
  "${DOCKER[@]}" logs --tail "$1" "$CONTAINER_NAME" 2>&1 \
    | sed -E 's/(sk-|libsql:\/\/|bot[0-9]+:)[A-Za-z0-9._-]+/\1***/g; s/^/'"$2"' /' || true
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
  [ "$OOM" = "true" ] && fail "${CONTAINER_NAME} hit the ${MEMORY_LIMIT} memory cap; raise KONGMING_MEMORY_LIMIT"
  fail "${CONTAINER_NAME} is not staying up (Turso credentials wrong?)"
fi

PROBE=""
PROBE_HOST="$BIND"; [ "$BIND" = "0.0.0.0" ] && PROBE_HOST=127.0.0.1
PROBE_PORT="$PORT"; [ "$NETWORK" = "host" ] && PROBE_PORT="$CPORT"
if command -v curl >/dev/null 2>&1; then
  PROBE="$(curl -fsS -m 5 "http://${PROBE_HOST}:${PROBE_PORT}/health" 2>/dev/null || true)"
elif command -v wget >/dev/null 2>&1; then
  PROBE="$(wget -qO- -T 5 "http://${PROBE_HOST}:${PROBE_PORT}/health" 2>/dev/null || true)"
fi
if [ -n "$PROBE" ]; then
  ok "HTTP answering on port ${PROBE_PORT} (health: $(echo "$PROBE" | tr -d '\n' | cut -c1-60))"
elif command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
  show_logs 20 '[!]  ' >&2
  fail "no HTTP answer on ${PROBE_HOST}:${PROBE_PORT}/health"
else
  warn "no curl/wget on the host, skipped the HTTP probe"
fi
[ "${INIT_DEBUG:-0}" = "1" ] && show_logs 10 '[d]  '

# The agents' shell is for interacting, not storage: nothing in the container may be writable.
WRITABLE="$("${DOCKER[@]}" exec "$CONTAINER_NAME" /opt/busybox/bin/sh -c 'for d in / /tmp /var/tmp /run /dev /dev/shm /dev/mqueue /opt /usr/local/bin; do [ -d "$d" ] && touch "$d/.kongming-w" 2>/dev/null && rm -f "$d/.kongming-w" && echo "$d"; done; true' 2>/dev/null | tr '\n' ' ' || true)"
if [ -z "$WRITABLE" ]; then
  ok "no writable storage in the container (the agents' shell can only interact)"
else
  warn "writable in the container: ${WRITABLE}"
fi

# The agents' curl and wget (kongming's own HTTP client) must reach the web over HTTPS.
FETCH="$("${DOCKER[@]}" exec "$CONTAINER_NAME" /opt/busybox/bin/sh -c 'PATH=/opt/busybox/bin:/usr/local/bin:/usr/bin:/bin; exec 2>&1; curl -sS -o /dev/null -m 20 -w "%{http_code}" https://example.com; echo " curl=$?"; wget -q -O /dev/null -T 20 https://example.com; echo "wget=$?"' 2>&1 | tr '\n' ' ' | cut -c1-300 || true)"
case "$FETCH" in
  "200 curl=0 wget=0 ") ok "agents' curl and wget fetch over HTTPS" ;;
  *) warn "agents' curl/wget check failed: ${FETCH:-no output}" ;;
esac

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE}"
echo "[*] published: $([ "$NETWORK" = "host" ] && echo "host network, port ${CPORT}" || echo "${BIND}:${PORT} (container port ${CPORT})") | ui: / | api: /api"
echo "[*] storage: none (Turso is the only copy)"
echo "[*] limits: cpu ${CPU_LIMIT}, memory ${MEMORY_LIMIT} (no swap), pids 64"
echo "[*] memory: ${MEM:-unknown}"
ok "init kongming done"

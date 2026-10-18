#!/bin/bash
# bash-scripts/init-dozzle.sh
# Idempotent deploy/update of Dozzle (amir20/dozzle): a light web UI for container logs, stats and
# start/stop/restart. Works on the GCP free-tier e2-micro (amd64, COS) and on an Orange Pi Zero 3
# (arm64, Armbian/Debian): the image is multi-arch and nothing below is distro-specific. Only
# docker is required; curl, ss, ip, findmnt and tailscale are used when present.
#
# Footprint (sized for the Zero 3): ~15-25 MB RSS, 1 Go thread, warn-level logging, no healthcheck
# process, no outbound calls (analytics, release/image checks, avatars). CPU/memory/pids caps are
# applied only when the kernel's cgroups support them, so it also runs on boards without them.
#
# Security model (this repo is public and its Actions logs are public):
#   - The UI listens on the Tailscale IP only (127.0.0.1 if Tailscale is not up). Never 0.0.0.0.
#   - Login is required (simple auth, bcrypt users.yml). The password is read from the
#     DOZZLE_PASSWORD secret, piped over stdin to `dozzle generate`, and never printed.
#   - The in-browser shell is OFF unless DOZZLE_SHELL=1. Setup wizard, MCP, analytics,
#     release/image checks and auto-update are off; settings passed as env are locked in the UI.
#
# Env:
#   DOZZLE_PASSWORD        login password (or DOZZLE_PASSWORD_FILE). Optional once users.yml exists.
#   DOZZLE_USER            login name (default admin)
#   DOZZLE_PORT            listen port (default 8080)
#   DOZZLE_BIND            listen address (default: Tailscale IPv4, else 127.0.0.1)
#   DOZZLE_SHELL           1 = enable the in-browser shell (default 0)
#   DOZZLE_AUTH_TTL        login lifetime, s/m/h units (default 24h)
#   DOZZLE_CPU_LIMIT       default 0.25
#   DOZZLE_MEMORY_LIMIT    default 48m (the Go heap target is 3/4 of it)
#   DOZZLE_DATA_DIR        host dir mounted at /data (default /var/lib/dozzle)
#   DOZZLE_IMAGE           default amir20/dozzle:latest
#   DOZZLE_REPLACE_PORTAINER  1 = remove the portainer container afterwards (its volume is kept)

set -euo pipefail

CONTAINER_NAME="dozzle"
IMAGE="${DOZZLE_IMAGE:-amir20/dozzle:latest}"
LOGIN_USER="${DOZZLE_USER:-admin}"
PORT="${DOZZLE_PORT:-8080}"
BIND="${DOZZLE_BIND:-}"
SHELL_ENABLED="${DOZZLE_SHELL:-0}"
AUTH_TTL="${DOZZLE_AUTH_TTL:-24h}"
CPU_LIMIT="${DOZZLE_CPU_LIMIT:-0.25}"
MEMORY_LIMIT="${DOZZLE_MEMORY_LIMIT:-48m}"
DATA_DIR="${DOZZLE_DATA_DIR:-/var/lib/dozzle}"
USERS_FILE="${DATA_DIR}/users.yml"
STAMP="${DATA_DIR}/.users.sha256"

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

# Lowest CPU/IO priority: both target boxes are small
renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

status "init dozzle start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"
DOCKER_INFO="$("${DOCKER[@]}" info --format '{{json .}}' 2>/dev/null)" || fail "docker daemon is not available"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "DOZZLE_PORT must be 1-65535"
[[ "$AUTH_TTL" =~ ^[0-9]+[smh]$ ]] || fail "DOZZLE_AUTH_TTL must look like 30m, 24h or 3600s"
[[ "$MEMORY_LIMIT" =~ ^[0-9]+[mMgG]$ ]] || fail "DOZZLE_MEMORY_LIMIT must look like 48m or 1g"

# Resource caps, each only where the kernel supports it (docker refuses --cpus without CFS quota)
has() { printf '%s' "$DOCKER_INFO" | grep -q "\"$1\":true"; }
LIMITS=()
has CpuCfsQuota && LIMITS+=(--cpus "$CPU_LIMIT")
if has MemoryLimit; then
  LIMITS+=(--memory "$MEMORY_LIMIT")
  has SwapLimit && LIMITS+=(--memory-swap "$MEMORY_LIMIT")
fi
has PidsLimit && LIMITS+=(--pids-limit 64)
# Go heap target at 3/4 of the cap, so the GC works harder well before the OOM killer would
MEM_MIB="${MEMORY_LIMIT%?}"
case "$MEMORY_LIMIT" in *[gG]) MEM_MIB=$(( MEM_MIB * 1024 )) ;; esac
GO_MEM_LIMIT="$(( MEM_MIB * 3 / 4 ))MiB"

ARCH="$(uname -m)"
# SD/eMMC root (Orange Pi, Raspberry Pi): keep container logs tiny to limit flash wear
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ "$ROOT_SRC" == /dev/mmcblk* ]]; then
  LOG_OPTS=(--log-opt max-size=1m --log-opt max-file=1)
  MEDIA="sd/emmc"
else
  LOG_OPTS=(--log-opt max-size=5m --log-opt max-file=2)
  MEDIA="disk"
fi
ok "docker ready (arch ${ARCH}, root on ${MEDIA}, caps: ${LIMITS[*]:-none supported})"

# ---------------------------------------------------------------------------
# 2. Listen address: Tailscale only, loopback as fallback
# ---------------------------------------------------------------------------
step "resolving listen address"
if [ -z "$BIND" ]; then
  for candidate in tailscale /var/lib/docker/tailscale-bin/tailscale /var/lib/cloud/tailscale-bin/tailscale /usr/bin/tailscale /usr/local/bin/tailscale; do
    if [ "$candidate" = "tailscale" ]; then
      command -v tailscale >/dev/null 2>&1 || continue
    elif ! "${SUDO[@]}" test -x "$candidate"; then
      continue
    fi
    BIND="$("${SUDO[@]}" "$candidate" ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
    [ -n "$BIND" ] && break
  done
fi
if [ -z "$BIND" ]; then
  BIND="$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
fi
if [ -z "$BIND" ]; then
  BIND="127.0.0.1"
  warn "no tailscale address found; listening on 127.0.0.1 only (use an ssh tunnel, or run init-tailscale first)"
fi
case "$BIND" in
  0.0.0.0|::|"[::]") fail "refusing to listen on all interfaces; DOZZLE_BIND must be a Tailscale or loopback address" ;;
esac
ok "listen address resolved"

# ---------------------------------------------------------------------------
# 3. Image
# ---------------------------------------------------------------------------
step "pulling ${IMAGE}"
PULLED=0
for attempt in 1 2 3; do
  if "${DOCKER[@]}" pull "$IMAGE" >/dev/null 2>&1; then PULLED=1; break; fi
  warn "pull failed (attempt ${attempt}/3)"
  [ "$attempt" -lt 3 ] && sleep $(( attempt * 5 ))
done
[ "$PULLED" = "1" ] || fail "failed to pull ${IMAGE}; check DNS/IPv6 access to Docker Hub"
ok "image ready"

# ---------------------------------------------------------------------------
# 4. Login: users.yml (bcrypt), regenerated only when user/password/roles change
# ---------------------------------------------------------------------------
step "preparing login"
"${SUDO[@]}" mkdir -p "$DATA_DIR"
"${SUDO[@]}" chmod 700 "$DATA_DIR"

PASSWORD="${DOZZLE_PASSWORD:-}"
if [ -z "$PASSWORD" ] && [ -n "${DOZZLE_PASSWORD_FILE:-}" ]; then
  PASSWORD="$("${SUDO[@]}" head -n1 "$DOZZLE_PASSWORD_FILE" | tr -d '\r\n')"
fi

ROLES="actions,download"
[ "$SHELL_ENABLED" = "1" ] && ROLES="${ROLES},shell"

if [ -n "$PASSWORD" ]; then
  [ "${#PASSWORD}" -ge 12 ] || fail "DOZZLE_PASSWORD must be at least 12 characters"
  WANT_SUM="$(printf '%s\n%s\n%s\n' "$LOGIN_USER" "$PASSWORD" "$ROLES" | sha256sum | awk '{print $1}')"
  HAVE_SUM="$("${SUDO[@]}" cat "$STAMP" 2>/dev/null || true)"
  if [ "$WANT_SUM" = "$HAVE_SUM" ] && "${SUDO[@]}" test -s "$USERS_FILE"; then
    ok "login unchanged"
  else
    # Password goes over stdin, never argv: argv is visible in `ps` and in the container config
    umask 077
    USERS_YML="$(printf '%s\n' "$PASSWORD" | "${DOCKER[@]}" run -i --rm --network none \
      -e DOZZLE_NO_ANALYTICS=true "$IMAGE" generate "$LOGIN_USER" --user-roles "$ROLES" 2>/dev/null)" \
      || fail "dozzle generate failed"
    printf '%s\n' "$USERS_YML" | grep -q 'password:' || fail "dozzle generate returned no password hash"
    printf '%s\n' "$USERS_YML" | "${SUDO[@]}" tee "${USERS_FILE}.tmp" >/dev/null
    "${SUDO[@]}" chmod 600 "${USERS_FILE}.tmp"
    "${SUDO[@]}" mv -f "${USERS_FILE}.tmp" "$USERS_FILE"
    printf '%s\n' "$WANT_SUM" | "${SUDO[@]}" tee "$STAMP" >/dev/null
    "${SUDO[@]}" chmod 600 "$STAMP"
    unset USERS_YML
    ok "login written (${USERS_FILE}, mode 600, value not logged)"
  fi
elif "${SUDO[@]}" test -s "$USERS_FILE"; then
  ok "DOZZLE_PASSWORD not set; keeping existing login"
else
  fail "no login configured: set the DOZZLE_PASSWORD secret (12+ chars) for the first run"
fi
unset PASSWORD

# ---------------------------------------------------------------------------
# 5. Replace the container
# ---------------------------------------------------------------------------
step "removing existing ${CONTAINER_NAME} container"
"${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
ok "old container gone"

if command -v ss >/dev/null 2>&1 && [ -n "$(ss -Hltn "sport = :${PORT}" 2>/dev/null)" ]; then
  fail "port ${PORT} is already in use by something else; set DOZZLE_PORT"
fi
CAPS=(--cap-drop ALL)
[ "$PORT" -lt 1024 ] && CAPS+=(--cap-add NET_BIND_SERVICE)

# Host network + DOZZLE_ADDR instead of -p: if Tailscale isn't up yet at boot, Dozzle exits on the
# failed bind and the restart policy retries it. A failed -p bind at boot is never retried by Docker.
# Settings passed as env are locked in the UI, so they are all set explicitly.
step "starting ${CONTAINER_NAME}"
"${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${DATA_DIR}:/data" \
  "${LIMITS[@]}" \
  "${CAPS[@]}" --security-opt no-new-privileges \
  --no-healthcheck \
  --log-driver json-file "${LOG_OPTS[@]}" \
  -e DOZZLE_ADDR="${BIND}:${PORT}" \
  -e DOZZLE_LEVEL=warn \
  -e DOZZLE_HOSTNAME="${TS_HOSTNAME:-$(hostname)}" \
  -e DOZZLE_AUTH_PROVIDER=simple \
  -e DOZZLE_AUTH_TTL="$AUTH_TTL" \
  -e DOZZLE_ENABLE_ACTIONS=true \
  -e DOZZLE_ENABLE_SHELL="$([ "$SHELL_ENABLED" = "1" ] && echo true || echo false)" \
  -e DOZZLE_ENABLE_MCP=false \
  -e DOZZLE_DISABLE_SETUP_WIZARD=true \
  -e DOZZLE_NO_ANALYTICS=true \
  -e DOZZLE_RELEASE_CHECK_MODE=manual \
  -e DOZZLE_IMAGE_CHECK_MODE=off \
  -e DOZZLE_AUTO_UPDATE=off \
  -e DOZZLE_DISABLE_AVATARS=true \
  -e GOMAXPROCS=1 \
  -e GOMEMLIMIT="$GO_MEM_LIMIT" \
  "$IMAGE" >/dev/null || fail "failed to start ${CONTAINER_NAME}"

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
step "waiting for the UI"
UP=0
for _ in $(seq 1 20); do
  STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
  [ "$STATE" = "running" ] || { sleep 1; continue; }
  if command -v curl >/dev/null 2>&1; then
    CODE="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://${BIND}:${PORT}/" 2>/dev/null || true)"
    if [[ "$CODE" =~ ^[23] ]] || [ "$CODE" = "401" ]; then UP=1; break; fi
  elif timeout 3 bash -c "exec 3<>/dev/tcp/${BIND}/${PORT}" 2>/dev/null; then
    CODE="tcp-open"; UP=1; break
  fi
  sleep 1
done
if [ "$UP" != "1" ]; then
  warn "state: ${STATE:-unknown}, http: ${CODE:-none}"
  "${DOCKER[@]}" logs --tail 20 "$CONTAINER_NAME" 2>&1 | sed 's/^/[!]   /' >&2 || true
  fail "${CONTAINER_NAME} is not answering"
fi
ok "${CONTAINER_NAME} is up"

if [ "${DOZZLE_REPLACE_PORTAINER:-0}" = "1" ]; then
  step "removing portainer (volume kept)"
  "${DOCKER[@]}" rm -f portainer >/dev/null 2>&1 && ok "portainer removed" || ok "no portainer container"
fi

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] listen: $([ "$BIND" = "127.0.0.1" ] && echo "loopback" || echo "tailscale") port ${PORT}"
echo "[*] user: ${LOGIN_USER}   roles: ${ROLES}"
echo "[*] shell: $([ "$SHELL_ENABLED" = "1" ] && echo enabled || echo disabled)"
echo "[*] memory: ${MEM:-unknown}"
ok "init dozzle done"

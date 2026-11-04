#!/bin/bash
# bash-scripts/init-dengai.sh
# Idempotent deploy/update of dengai (sudtanj/dengai, a small Rust Steam bot, see builder-tools/dengai/)
# on a small board, tuned for the Orange Pi Zero 3 (4x A53, 1 GB RAM, SD card):
#   - API published only on 127.0.0.1 by default; DENGAI_BIND opens it deliberately (e.g. a Tailscale IP)
#   - read-only rootfs, all caps dropped, no-new-privileges, 64 MB RAM cap without swap, 0.5 CPU
#   - state (the Steam refresh token) lives in the named volume dengai-data mounted at /data
#
# DENGAI_PASSWORD is only needed until the first login has saved a refresh token in /data;
# after that it can be removed from the repo secrets (the script then simply does not pass it).
#
# Security model (this repo and its Actions logs are public): secret values are never printed
# and never put on a command line; they reach docker through a 0600 env file deleted right
# after `docker run`.
#
# Env (only the DENGAI_* variables that are set reach the container):
#   DENGAI_USERNAME             Steam account name (required)
#   DENGAI_PASSWORD             Steam password, see above
#   DENGAI_SHARED_SECRET        Steam Guard shared secret (otherwise approve the login in the Steam app)
#   DENGAI_GUARD_CODE           one-off Steam Guard code
#   DENGAI_API_TOKEN            bearer token for the HTTP API (empty = API disabled; 16+ characters)
#   DENGAI_BACKFILL_URL         optional backfill source URL
#   DENGAI_CLAIMS_PER_HOUR, DENGAI_SKIP_DEMOS, DENGAI_SKIP_PLAYTESTS, DENGAI_COUNTRY, DENGAI_LOG,
#   DENGAI_AUTO_CLAIM_APPS, DENGAI_BACKFILL_INTERVAL_SECS   see builder-tools/dengai/.env.example
# Script-only settings (not passed to the container):
#   DENGAI_BIND                 host address to publish on, default 127.0.0.1
#   DENGAI_PORT                 host port, default 8737 (container always listens on 8737)
#   DENGAI_IMAGE                default sudtanj/dengai:latest; pin a release (sudtanj/dengai:v0.1.2) so a
#                               rebuilt :latest cannot reach the account unreviewed
# Anything else starting with DENGAI_ that is set is passed through too.
#
# Rollback: the image that was running is tagged dengai:previous before the pull. If the new
# container does not stay up, it is replaced by dengai:previous and the run fails. The old
# image is deleted only after the new one passed the check.

set -euo pipefail

CONTAINER_NAME="dengai"
VOLUME_NAME="dengai-data"
IMAGE="${DENGAI_IMAGE:-sudtanj/dengai:latest}"
BIND="${DENGAI_BIND:-127.0.0.1}"
PORT="${DENGAI_PORT:-8737}"   # host side
CPORT=8737                    # container side
CPU_LIMIT="0.5"
MEMORY_LIMIT="64m"
PIDS_LIMIT=32
CONFIG_REV="2"   # bump when the docker run flags below change
PREVIOUS_TAG="dengai:previous"
SALT_FILE="/var/lib/dengai-deploy/salt"
CHECK_SECS=30

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
debug()  { [ "${INIT_DEBUG:-0}" = "1" ] && printf '%s\n' "[d] $*" || true; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo); fi
if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then DOCKER=(docker); else DOCKER=(sudo docker); fi

renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

status "init dengai start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
[ -n "${DENGAI_USERNAME:-}" ] || fail "DENGAI_USERNAME is not set (add it as a repo secret)"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  *) fail "unsupported arch $(uname -m); the image is built for amd64 and arm64 only" ;;
esac
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || fail "DENGAI_PORT must be a number"
[[ "$BIND" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "DENGAI_BIND must be an IPv4 address"
if [ "$BIND" = "0.0.0.0" ] && [ "${DENGAI_ALLOW_ANY:-0}" != "1" ]; then
  fail "DENGAI_BIND=0.0.0.0 exposes the API on every interface; set DENGAI_ALLOW_ANY=1 if that is intended"
fi
if [ -z "${DENGAI_API_TOKEN:-}" ]; then
  warn "DENGAI_API_TOKEN unset: the HTTP API is disabled"
elif [ "${#DENGAI_API_TOKEN}" -lt 16 ]; then
  warn "DENGAI_API_TOKEN is under 16 characters: dengai will reject it in a coming release"
fi
if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :${PORT}" 2>/dev/null | grep -q . \
   && ! "${DOCKER[@]}" inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  fail "port ${PORT} is already in use on the host"
fi
ok "docker ready"

# Names of the DENGAI_* variables that are set, minus the script-only ones.
ENV_NAMES=()
while IFS= read -r v; do
  case "$v" in DENGAI_BIND|DENGAI_PORT|DENGAI_IMAGE|DENGAI_ALLOW_ANY) continue ;; esac
  [ -n "${!v:-}" ] && ENV_NAMES+=("$v")
done < <(compgen -e | grep '^DENGAI_' | sort || true)
debug "passing env names: ${ENV_NAMES[*]:-none}"

# ---------------------------------------------------------------------------
# 2. Image
# ---------------------------------------------------------------------------
OLD_IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
# Roll back to what is running, which can differ from the local $IMAGE tag.
PREV_ID="$("${DOCKER[@]}" inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || echo "$OLD_IMAGE_ID")"
if [ -n "$PREV_ID" ] && ! "${DOCKER[@]}" tag "$PREV_ID" "$PREVIOUS_TAG" >/dev/null 2>&1; then
  warn "could not tag ${PREVIOUS_TAG}: no rollback image this run"
  PREV_ID=""
fi
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
# docker run with the env file, which exists only for the duration of the call. Values are
# written raw, one per line (docker --env-file is literal), so a newline would inject a variable.
start_container() {
  local image="$1" label="$2" v rc=0
  for v in "${ENV_NAMES[@]}"; do
    case "${!v}" in *$'\n'*) fail "$v contains a newline, which docker --env-file cannot carry" ;; esac
  done
  ENV_FILE="$(umask 077; mktemp)"
  trap 'rm -f "$ENV_FILE"' EXIT
  for v in "${ENV_NAMES[@]}"; do printf '%s=%s\n' "$v" "${!v}"; done > "$ENV_FILE"
  # on-failure:5, not unless-stopped: a rejected Steam login must not restart-loop into an account lock.
  "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
    --restart on-failure:5 \
    -p "${BIND}:${PORT}:${CPORT}" \
    --env-file "$ENV_FILE" \
    --label "dengai.config=${label}" \
    -v "${VOLUME_NAME}:/data" \
    --read-only \
    --cpus "$CPU_LIMIT" \
    --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" \
    --pids-limit "$PIDS_LIMIT" \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-driver json-file --log-opt max-size=1m --log-opt max-file=1 \
    "$image" >/dev/null || rc=$?
  rm -f "$ENV_FILE"
  return "$rc"
}

# Keyed hash of every setting (secrets included, never printed), stored as a label. The salt is
# root-only, so someone who can read the label (docker group) cannot brute-force the secrets offline.
"${SUDO[@]}" sh -c 'umask 077; mkdir -p "$(dirname "$1")"; [ -s "$1" ] || head -c 32 /dev/urandom | base64 > "$1"' _ "$SALT_FILE" \
  || fail "cannot create ${SALT_FILE}"
SALT="$("${SUDO[@]}" cat "$SALT_FILE")"
WANT_SUM="$({
  printf '%s\n' "$SALT" "$IMAGE_ID" "$PORT" "$BIND" "$CPU_LIMIT" "$MEMORY_LIMIT" "$PIDS_LIMIT" "$CONFIG_REV"
  for v in "${ENV_NAMES[@]}"; do printf '%s=%s\n' "$v" "${!v}"; done
} | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "dengai.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
RECREATED=0
CHECK_SINCE="$(date +%s)"

if [ "$WANT_SUM" = "$HAVE_SUM" ] && [ "$STATE" = "running" ]; then
  ok "${CONTAINER_NAME} already running with the current image and settings"
else
  debug "recreate reason: state=${STATE}, config $([ "$WANT_SUM" = "$HAVE_SUM" ] && echo same || echo changed)"

  step "removing existing ${CONTAINER_NAME} container"
  "${DOCKER[@]}" stop -t 15 "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  ok "old container gone (volume ${VOLUME_NAME} kept)"

  step "starting ${CONTAINER_NAME}"
  start_container "$IMAGE" "$WANT_SUM" || fail "failed to start ${CONTAINER_NAME}"
  RECREATED=1
fi

# ---------------------------------------------------------------------------
# 4. Verify: running and not restart-looping
# ---------------------------------------------------------------------------
# Logs may mention the account: mask the username, the known secret values exactly, and anything token-like.
show_logs() {
  local line s v secrets=()
  for v in DENGAI_PASSWORD DENGAI_SHARED_SECRET DENGAI_API_TOKEN DENGAI_GUARD_CODE; do
    [ -n "${!v:-}" ] && secrets+=("${!v}")
  done
  "${DOCKER[@]}" logs --tail "$1" "$CONTAINER_NAME" 2>&1 \
    | while IFS= read -r line || [ -n "$line" ]; do
        for s in "${secrets[@]}"; do line="${line//"$s"/<redacted>}"; done
        printf '%s\n' "$line"
      done \
    | sed -E "s/$(printf '%s' "$DENGAI_USERNAME" | sed 's/[][\.*^$/|+?(){}]/\\&/g')/<user>/g; s/[A-Za-z0-9_-]{32,}/<redacted>/g; s/^/$2 /" || true
}

inspect_dengai() { "${DOCKER[@]}" inspect -f "$1" "$CONTAINER_NAME" 2>/dev/null || echo "$2"; }

step "checking ${CONTAINER_NAME} stays up for ${CHECK_SECS}s"
if [ "$RECREATED" = "1" ]; then RESTARTS_BEFORE=0; else RESTARTS_BEFORE="$(inspect_dengai '{{.RestartCount}}' 0)"; fi
STABLE=1
for (( t = 0; t < CHECK_SECS; t += 2 )); do
  STATE="$(inspect_dengai '{{.State.Status}}' missing)"
  RESTARTS="$(inspect_dengai '{{.RestartCount}}' 0)"
  if [ "$STATE" != "running" ] || [ "${RESTARTS:-0}" -gt "$RESTARTS_BEFORE" ]; then STABLE=0; break; fi
  sleep 2
done

if [ "$STABLE" != "1" ]; then
  warn "state: ${STATE}, restarts during check: $(( ${RESTARTS:-0} - RESTARTS_BEFORE ))"
  show_logs 20 '[!]  ' >&2
  # OOMKilled resets on every restart, so a restart loop hides it: ask the daemon's event log too.
  OOM_EVENTS="$("${DOCKER[@]}" events --since "$CHECK_SINCE" --until "$(date +%s)" \
    --filter "container=${CONTAINER_NAME}" --filter event=oom 2>/dev/null | grep -c . || true)"
  if [ "$(inspect_dengai '{{.State.OOMKilled}}' false)" = "true" ] || [ "${OOM_EVENTS:-0}" -gt 0 ]; then
    REASON="hit the ${MEMORY_LIMIT} memory cap"
  else
    REASON="is not staying up (check the Steam credentials, see the logs above)"
  fi
  if [ "$RECREATED" = "1" ] && [ -n "$PREV_ID" ]; then
    warn "rolling back to ${PREVIOUS_TAG}"
    "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    start_container "$PREVIOUS_TAG" "rolled-back" \
      || fail "${CONTAINER_NAME} ${REASON}; rollback to ${PREVIOUS_TAG} also failed to start"
    fail "${CONTAINER_NAME} ${REASON}; rolled back to ${PREVIOUS_TAG}, pin DENGAI_IMAGE to a good release"
  fi
  fail "${CONTAINER_NAME} ${REASON}; no previous image to roll back to"
fi
ok "${CONTAINER_NAME} is up"
[ "${INIT_DEBUG:-0}" = "1" ] && show_logs 10 '[d]  '

# The new image is proven: drop the rollback tag, then the old image if nothing uses it.
if [ -n "$PREV_ID" ]; then
  "${DOCKER[@]}" rmi "$PREVIOUS_TAG" >/dev/null 2>&1 || true
  if [ "$PREV_ID" != "$IMAGE_ID" ]; then
    "${DOCKER[@]}" rmi "$PREV_ID" >/dev/null 2>&1 && debug "removed previous image" || true
  fi
fi

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE}"
echo "[*] published: ${BIND}:${PORT} (container port ${CPORT})"
echo "[*] storage: volume ${VOLUME_NAME} at /data"
echo "[*] limits: cpu ${CPU_LIMIT}, memory ${MEMORY_LIMIT} (no swap), pids ${PIDS_LIMIT}"
echo "[*] memory: ${MEM:-unknown}"
ok "init dengai done"

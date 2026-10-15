#!/bin/bash
# bash-scripts/orangepi/init-honeygain.sh
# Idempotent deploy/update of Honeygain (sudtanj/honeygain: the official client on distroless,
# see builder-tools/honeygain/). Meant for a home device like an Orange Pi Zero 3: Honeygain
# rejects datacenter IPs, which is why this lives outside bash-scripts/ and the GCP runner's
# "all" never picks it up.
#
# Security model (this repo is public and its Actions logs are public):
#   - Account email, password and device name are never printed.
#   - The binary only accepts the password as -pass, so it is visible to root on the device
#     (`docker inspect`, `ps`). Nothing else leaves the device.
#
# Env:
#   HONEYGAIN_EMAIL         account email (required)
#   HONEYGAIN_PASSWORD      account password (required)
#   HONEYGAIN_DEVICE        dashboard device name, also the container hostname (default: this
#                           machine's hostname). Keep it stable, or each change is a new device.
#   HONEYGAIN_IMAGE         default sudtanj/honeygain:latest
#   HONEYGAIN_CPU_LIMIT     default 0.5
#   HONEYGAIN_MEMORY_LIMIT  default 128m
#   HONEYGAIN_DNS           space-separated resolvers for the container (default: AdGuard Family
#                           Protection, 94.140.14.15 94.140.14.16), which blocks known malware,
#                           phishing and adult domains for every lookup the client makes.
#                           "system" uses the host's resolver instead.

set -euo pipefail

CONTAINER_NAME="honeygain"
VOLUME_NAME="honeygain-data"
IMAGE="${HONEYGAIN_IMAGE:-sudtanj/honeygain:latest}"
EMAIL="${HONEYGAIN_EMAIL:-}"
PASSWORD="${HONEYGAIN_PASSWORD:-}"
DEVICE="${HONEYGAIN_DEVICE:-$(hostname)}"
CPU_LIMIT="${HONEYGAIN_CPU_LIMIT:-0.5}"
MEMORY_LIMIT="${HONEYGAIN_MEMORY_LIMIT:-128m}"
DNS_SERVERS="${HONEYGAIN_DNS:-94.140.14.15 94.140.14.16}"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
debug()  { [ "${INIT_DEBUG:-0}" = "1" ] && printf '%s\n' "[d] $*" || true; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi

renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

status "init honeygain start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
[ -n "$EMAIL" ] || fail "HONEYGAIN_EMAIL is not set"
[ -n "$PASSWORD" ] || fail "HONEYGAIN_PASSWORD is not set"
[[ "$DEVICE" =~ ^[A-Za-z0-9._-]{1,63}$ ]] || fail "HONEYGAIN_DEVICE must be 1-63 chars of letters, digits, . _ -"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64|arm64) ;;
  *) fail "unsupported arch ${ARCH}; the image is built for amd64 and arm64 only" ;;
esac

ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ "$ROOT_SRC" == /dev/mmcblk* ]]; then
  LOG_OPTS=(--log-opt max-size=1m --log-opt max-file=1)
  MEDIA="sd/emmc"
else
  LOG_OPTS=(--log-opt max-size=5m --log-opt max-file=2)
  MEDIA="disk"
fi
DNS_OPTS=()
if [ "$DNS_SERVERS" != "system" ]; then
  for d in $DNS_SERVERS; do
    [[ "$d" =~ ^[0-9a-fA-F.:]+$ ]] || fail "HONEYGAIN_DNS entries must be IP addresses"
    DNS_OPTS+=(--dns "$d")
  done
fi
ok "docker ready (arch ${ARCH}, root on ${MEDIA})"

# ---------------------------------------------------------------------------
# 2. Image
# ---------------------------------------------------------------------------
step "pulling ${IMAGE}"
PULLED=0
for attempt in 1 2 3; do
  if "${DOCKER[@]}" pull "$IMAGE" >/dev/null 2>&1; then PULLED=1; break; fi
  warn "pull failed (attempt ${attempt}/3)"
  [ "$attempt" -lt 3 ] && sleep $(( attempt * 5 ))
done
[ "$PULLED" = "1" ] || fail "failed to pull ${IMAGE}"
IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE")"
ok "image ready"

# ---------------------------------------------------------------------------
# 3. Skip the restart when nothing changed
# ---------------------------------------------------------------------------
# A hash of every setting (credentials included, never printed) is stored as a label, so an
# unchanged run leaves a healthy container alone instead of reconnecting it.
WANT_SUM="$(printf '%s\n' "$IMAGE_ID" "$EMAIL" "$PASSWORD" "$DEVICE" "$CPU_LIMIT" "$MEMORY_LIMIT" "$DNS_SERVERS" "v1" \
  | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "honeygain.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"

if [ "$WANT_SUM" = "$HAVE_SUM" ] && [ "$STATE" = "running" ]; then
  ok "${CONTAINER_NAME} already running with the current image and settings"
else
  debug "recreate reason: state=${STATE}, config $([ "$WANT_SUM" = "$HAVE_SUM" ] && echo same || echo changed)"

  # -------------------------------------------------------------------------
  # 4. Replace the container
  # -------------------------------------------------------------------------
  step "removing existing ${CONTAINER_NAME} container"
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  ok "old container gone (state volume ${VOLUME_NAME} kept)"

  step "starting ${CONTAINER_NAME}"
  "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --hostname "$DEVICE" \
    "${DNS_OPTS[@]}" \
    --label "honeygain.config=${WANT_SUM}" \
    -v "${VOLUME_NAME}:/home/nonroot" \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --cpus "$CPU_LIMIT" --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" --pids-limit 128 \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-driver json-file "${LOG_OPTS[@]}" \
    "$IMAGE" \
    -tou-accept -email "$EMAIL" -pass "$PASSWORD" -device "$DEVICE" >/dev/null \
    || fail "failed to start ${CONTAINER_NAME}"
fi
unset PASSWORD

# ---------------------------------------------------------------------------
# 5. Verify: still running and not restart-looping after a short settle
# ---------------------------------------------------------------------------
step "checking ${CONTAINER_NAME} stays up"
sleep 15
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
RESTARTS="$("${DOCKER[@]}" inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
if [ "$STATE" != "running" ] || [ "${RESTARTS:-0}" -gt 0 ]; then
  warn "state: ${STATE}, restarts: ${RESTARTS}"
  # The workflow's sanitizer masks emails and secrets, but keep the tail short anyway
  "${DOCKER[@]}" logs --tail 15 "$CONTAINER_NAME" 2>&1 | sed 's/^/[!]   /' >&2 || true
  fail "${CONTAINER_NAME} is not staying up (wrong credentials, or a read-only path; see README)"
fi
if [ "${INIT_DEBUG:-0}" = "1" ]; then
  "${DOCKER[@]}" logs --tail 10 "$CONTAINER_NAME" 2>&1 | sed 's/^/[d]   /' || true
fi
ok "${CONTAINER_NAME} is up"

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE}"
echo "[*] limits: cpu ${CPU_LIMIT}, memory ${MEMORY_LIMIT}"
echo "[*] dns: $([ "$DNS_SERVERS" = "system" ] && echo "host resolver" || echo "filtered (${#DNS_OPTS[@]} resolver flags)")"
echo "[*] memory: ${MEM:-unknown}"
ok "init honeygain done"

#!/bin/bash
# bash-scripts/init-traffmonetizer.sh
# Idempotent deploy/update of Traffmonetizer (sudtanj/traffmonetizer: the official client on
# distroless, non-root, see builder-tools/traffmonetizer/). Run it on a home device (e.g. the
# Orange Pi Zero 3); datacenter IPs earn little or nothing.
#
# Security model (this repo is public and its Actions logs are public):
#   - The token and device name are never printed.
#   - The binary only accepts the token as --token, so it is visible to root on the device
#     (`docker inspect`, `ps`). Nothing else leaves the device.
#
# Env:
#   TRAFFMONETIZER_TOKEN         application token (required)
#   TRAFFMONETIZER_DEVICE        base dashboard device name (default: this machine's hostname).
#                                Every new container gets a random suffix (<base>-<6 hex>), used
#                                as both the device name and the container hostname. The device
#                                ID is not kept (it lives in a tmpfs), so each deployment is a
#                                fresh device.
#   TRAFFMONETIZER_IMAGE         default sudtanj/traffmonetizer:latest
#   TRAFFMONETIZER_CPU_LIMIT     hard CPU cap, default 0.25
#   TRAFFMONETIZER_MEMORY_LIMIT  hard RAM cap, swap disabled, default 64m
#
# DNS is not configurable: the container only resolves through AdGuard Family Protection
# (blocks known malware, phishing and adult domains). It runs on its own network, and firewall
# rules drop DNS (53) and DNS-over-TLS/QUIC (853) to any other server, so the client cannot
# bypass it. A systemd unit re-applies the rules after a reboot.

set -euo pipefail

CONTAINER_NAME="traffmonetizer"
NETWORK_NAME="traffmonetizer-net"
NETWORK_SUBNET="10.213.53.8/29"   # next to honeygain-net (10.213.53.0/29)
FW_CHAIN="TRAFFMON-DNS"
PIDS_LIMIT=128
IMAGE="${TRAFFMONETIZER_IMAGE:-sudtanj/traffmonetizer:latest}"
TOKEN="${TRAFFMONETIZER_TOKEN:-}"
DEVICE="${TRAFFMONETIZER_DEVICE:-$(hostname)}"
CPU_LIMIT="${TRAFFMONETIZER_CPU_LIMIT:-0.25}"
MEMORY_LIMIT="${TRAFFMONETIZER_MEMORY_LIMIT:-64m}"
DNS_SERVERS=(94.140.14.15 94.140.14.16)   # AdGuard Family Protection

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
debug()  { [ "${INIT_DEBUG:-0}" = "1" ] && printf '%s\n' "[d] $*" || true; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo); fi
if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo docker)
fi

renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

status "init traffmonetizer start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
[ -n "$TOKEN" ] || fail "TRAFFMONETIZER_TOKEN is not set"
[[ "$DEVICE" =~ ^[A-Za-z0-9._-]{1,56}$ ]] || fail "TRAFFMONETIZER_DEVICE must be 1-56 chars of letters, digits, . _ - (a 7-char suffix is added)"

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
command -v iptables >/dev/null 2>&1 || "${SUDO[@]}" test -x /usr/sbin/iptables \
  || fail "iptables is required to lock DNS to AdGuard"
DNS_OPTS=()
for d in "${DNS_SERVERS[@]}"; do DNS_OPTS+=(--dns "$d"); done
ok "docker ready (arch ${ARCH}, root on ${MEDIA})"

# ---------------------------------------------------------------------------
# 2. Own network + DNS lock
# ---------------------------------------------------------------------------
step "preparing network ${NETWORK_NAME}"
if ! "${DOCKER[@]}" network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  "${DOCKER[@]}" network create --driver bridge --subnet "$NETWORK_SUBNET" \
    -o com.docker.network.bridge.name=br-traffmon "$NETWORK_NAME" >/dev/null \
    || fail "failed to create ${NETWORK_NAME} (subnet ${NETWORK_SUBNET} may clash with another network)"
fi
HAVE_SUBNET="$("${DOCKER[@]}" network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME")"
[ "$HAVE_SUBNET" = "$NETWORK_SUBNET" ] || fail "${NETWORK_NAME} exists with another subnet; remove it and re-run"
ok "network ready"

# The rules live in a script + systemd unit, so a reboot (which wipes iptables) gets them back
# as soon as Docker is up. Traffic from the Traffmonetizer subnet to port 53/853 is only allowed
# towards the AdGuard servers; everything else on those ports is dropped.
step "locking DNS to AdGuard Family Protection"
LOCK_SCRIPT="/usr/local/sbin/traffmonetizer-dns-lock"
LOCK_UNIT="/etc/systemd/system/traffmonetizer-dns-lock.service"
{
  echo '#!/bin/sh'
  echo '# Generated by bash-scripts/init-traffmonetizer.sh. Idempotent.'
  echo 'set -e'
  echo "C=${FW_CHAIN}"
  echo 'iptables -N "$C" 2>/dev/null || iptables -F "$C"'
  for d in "${DNS_SERVERS[@]}"; do
    for p in udp tcp; do
      echo "iptables -A \"\$C\" -d ${d} -p ${p} --dport 53 -j RETURN"
      echo "iptables -A \"\$C\" -d ${d} -p ${p} --dport 853 -j RETURN"
    done
  done
  for p in udp tcp; do
    echo "iptables -A \"\$C\" -p ${p} --dport 53 -j DROP"
    echo "iptables -A \"\$C\" -p ${p} --dport 853 -j DROP"
  done
  echo 'iptables -N DOCKER-USER 2>/dev/null || true'
  echo "iptables -C DOCKER-USER -s ${NETWORK_SUBNET} -j \"\$C\" 2>/dev/null || iptables -I DOCKER-USER 1 -s ${NETWORK_SUBNET} -j \"\$C\""
} | "${SUDO[@]}" tee "$LOCK_SCRIPT" >/dev/null
"${SUDO[@]}" chmod 755 "$LOCK_SCRIPT"
"${SUDO[@]}" "$LOCK_SCRIPT" || fail "failed to apply the DNS firewall rules"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  printf '%s\n' \
    '[Unit]' \
    'Description=Lock Traffmonetizer container DNS to AdGuard Family Protection' \
    'After=docker.service' \
    'Requires=docker.service' \
    'PartOf=docker.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'RemainAfterExit=yes' \
    "ExecStart=${LOCK_SCRIPT}" \
    '' \
    '[Install]' \
    'WantedBy=docker.service' \
    | "${SUDO[@]}" tee "$LOCK_UNIT" >/dev/null
  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl enable traffmonetizer-dns-lock.service >/dev/null 2>&1 \
    || warn "could not enable traffmonetizer-dns-lock.service; re-run this script after a reboot"
else
  warn "no systemd: the DNS lock is not re-applied on reboot; re-run this script after one"
fi
ok "DNS locked (rules re-applied on boot)"

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
[ "$PULLED" = "1" ] || fail "failed to pull ${IMAGE}"
IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE")"
ok "image ready"

# ---------------------------------------------------------------------------
# 4. Skip the restart when nothing changed
# ---------------------------------------------------------------------------
# A hash of every setting (token included, never printed) is stored as a label, so an unchanged
# run leaves a healthy container alone instead of reconnecting it.
WANT_SUM="$(printf '%s\n' "$IMAGE_ID" "$TOKEN" "$DEVICE" "$CPU_LIMIT" "$MEMORY_LIMIT" "$PIDS_LIMIT" "${DNS_SERVERS[*]}" "$NETWORK_NAME" "v3" \
  | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "traffmonetizer.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"

if [ "$WANT_SUM" = "$HAVE_SUM" ] && [ "$STATE" = "running" ]; then
  ok "${CONTAINER_NAME} already running with the current image and settings"
else
  debug "recreate reason: state=${STATE}, config $([ "$WANT_SUM" = "$HAVE_SUM" ] && echo same || echo changed)"

  # -------------------------------------------------------------------------
  # 5. Replace the container
  # -------------------------------------------------------------------------
  step "removing existing ${CONTAINER_NAME} container"
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  # v0.1.0 kept the device ID in this volume; nothing uses it any more
  "${DOCKER[@]}" volume rm traffmonetizer-data >/dev/null 2>&1 || true
  ok "old container gone"

  # Fresh random suffix per new container, so each deployment has its own name. Not printed
  # (the base name is identifying).
  RUN_DEVICE="${DEVICE}-$(od -An -N3 -tx1 /dev/urandom | tr -d " \n")"
  [[ "$RUN_DEVICE" =~ -[0-9a-f]{6}$ ]] || fail "could not generate a device suffix"

  step "starting ${CONTAINER_NAME}"
  "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --hostname "$RUN_DEVICE" \
    --network "$NETWORK_NAME" \
    "${DNS_OPTS[@]}" \
    --label "traffmonetizer.config=${WANT_SUM}" \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=4m \
    --tmpfs /home/nonroot:rw,noexec,nosuid,nodev,size=1m,uid=65532,gid=65532,mode=0700 \
    --cpus "$CPU_LIMIT" --cpu-shares 256 \
    --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" \
    --oom-score-adj 500 \
    --pids-limit "$PIDS_LIMIT" \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-driver json-file "${LOG_OPTS[@]}" \
    "$IMAGE" \
    start accept --token "$TOKEN" --device-name "$RUN_DEVICE" >/dev/null \
    || fail "failed to start ${CONTAINER_NAME}"
fi

# ---------------------------------------------------------------------------
# 6. Verify: still running and not restart-looping after a short settle
# ---------------------------------------------------------------------------
# Container log tail with the token, the device name and any device ID (UUID or long hex)
# masked: this repo's logs are public.
show_logs() {
  local line
  "${DOCKER[@]}" logs --tail "$1" "$CONTAINER_NAME" 2>&1 \
    | grep -av '^[[:space:]]*$' \
    | sed -E 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<id>/g; s/[0-9A-Fa-f]{24,}/<id>/g' \
    | while IFS= read -r line; do
        line="${line//"$TOKEN"/<redacted>}"
        printf '%s %s\n' "$2" "${line//"$DEVICE"/<device>}"
      done || true
}

step "checking ${CONTAINER_NAME} stays up"
# RestartCount is cumulative over the container's lifetime, so only restarts during this
# settle window count as a failure; earlier ones are just reported.
RESTARTS_BEFORE="$("${DOCKER[@]}" inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
sleep 20
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
RESTARTS="$("${DOCKER[@]}" inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
OOM="$("${DOCKER[@]}" inspect -f '{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
if [ "$STATE" != "running" ] || [ "${RESTARTS:-0}" -gt "${RESTARTS_BEFORE:-0}" ]; then
  warn "state: ${STATE}, restarts during check: $(( ${RESTARTS:-0} - ${RESTARTS_BEFORE:-0} ))"
  show_logs 15 '[!]  ' >&2
  [ "$OOM" = "true" ] && fail "${CONTAINER_NAME} hit the ${MEMORY_LIMIT} memory cap; raise TRAFFMONETIZER_MEMORY_LIMIT"
  fail "${CONTAINER_NAME} is not staying up (wrong token, or a read-only path; see README)"
fi
if [ "${RESTARTS:-0}" -gt 0 ]; then
  LAST_EXIT="$("${DOCKER[@]}" inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo '?')"
  warn "${CONTAINER_NAME} restarted ${RESTARTS} time(s) since it was created (oom: ${OOM}, last exit code: ${LAST_EXIT}); stable during the check"
fi

# DNS: the container must use exactly the AdGuard servers, and the lock must be in place
step "verifying DNS lock"
HAVE_DNS="$("${DOCKER[@]}" inspect -f '{{join .HostConfig.Dns " "}}' "$CONTAINER_NAME")"
[ "$HAVE_DNS" = "${DNS_SERVERS[*]}" ] || fail "container DNS is not AdGuard Family Protection"
RESOLV="$("${DOCKER[@]}" inspect -f '{{.ResolvConfPath}}' "$CONTAINER_NAME")"
NS="$("${SUDO[@]}" grep -E '^nameserver' "$RESOLV" | awk '{print $2}' | paste -sd' ' -)"
[ "$NS" = "127.0.0.11" ] || [ "$NS" = "${DNS_SERVERS[*]}" ] || fail "unexpected nameserver in the container's resolv.conf"
"${SUDO[@]}" iptables -C DOCKER-USER -s "$NETWORK_SUBNET" -j "$FW_CHAIN" 2>/dev/null \
  || fail "DNS firewall rule is missing from DOCKER-USER"
ok "DNS: AdGuard Family Protection only, other resolvers blocked"
[ "${INIT_DEBUG:-0}" = "1" ] && show_logs 10 '[d]  '
unset TOKEN
ok "${CONTAINER_NAME} is up"

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE}"
echo "[*] limits: cpu ${CPU_LIMIT}, memory ${MEMORY_LIMIT} (no swap), pids ${PIDS_LIMIT}"
echo "[*] dns: AdGuard Family Protection (locked)"
echo "[*] memory: ${MEM:-unknown}"
ok "init traffmonetizer done"

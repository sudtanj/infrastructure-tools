#!/bin/bash
# bash-scripts/init-wipter.sh
# Idempotent deploy/update of Wipter (sudtanj/wipter: the official desktop app run headless, no X
# server or VNC, non-root, see builder-tools/wipter/). Run it on a home device (e.g. the Orange Pi
# Zero 3); datacenter IPs earn little or nothing, and Wipter flags non-residential IPs.
#
# Security model (this repo is public and its Actions logs are public):
#   - The email and password are never printed (masked in the client log). They are passed on the
#     `docker run` command line, visible to root on the device (`ps` while starting,
#     `docker inspect`). The launcher drops them from the app's environment.
#   - The app's session lives in the wipter-config volume, so a restart doesn't sign in again.
#
# Env:
#   WIPTER_EMAIL          Wipter account email (required)
#   WIPTER_PASSWORD       Wipter account password (required)
#   WIPTER_IMAGE          default sudtanj/wipter:latest
#   WIPTER_CPU_LIMIT      hard CPU cap, default 0.5 (Electron is slow to start below that)
#   WIPTER_MEMORY_LIMIT   hard RAM cap, swap disabled, default 512m
#
# Deploying accepts Wipter's bandwidth-sharing consent prompt for you (the launcher clicks
# "agree" when the app shows it): the app shares nothing until it is accepted.
#
# The app keeps a stable machine ID (its device fingerprint) in /var/lib/wipter/machine-id on the
# host, made once and mounted read-only as the container's /etc/machine-id: a new one would be a
# new device. The app reports that it runs in a container (it checks /.dockerenv and cgroups);
# nothing here hides that.
#
# DNS is not configurable from inside the app, so every DNS query from its network (port 53, UDP
# and TCP) is redirected to AdGuard Family Protection (blocks known malware, phishing and adult
# domains), and DNS-over-TLS (853) to any other server is dropped. All traffic to private,
# Tailscale, link-local and multicast ranges is dropped too: the app relays third-party traffic,
# which must not reach the LAN. A systemd unit re-applies the rules after a reboot.

set -euo pipefail

CONTAINER_NAME="wipter"
NETWORK_NAME="wipter-net"
NETWORK_SUBNET="10.213.53.64/29"  # after honeygain (.0), traffmonetizer (.8), earnfm (.16), repocket (.24), pawns (.32), packetstream (.40), bitping (.48), earnapp (.56)
FW_CHAIN="WIPTER-DNS"
NAT_CHAIN="WIPTER-DNS-NAT"
PIDS_LIMIT=256   # Chromium counts every thread
IMAGE="${WIPTER_IMAGE:-sudtanj/wipter:latest}"
EMAIL="${WIPTER_EMAIL:-}"
PASSWORD="${WIPTER_PASSWORD:-}"
CPU_LIMIT="${WIPTER_CPU_LIMIT:-0.5}"
MEMORY_LIMIT="${WIPTER_MEMORY_LIMIT:-512m}"
VOLUME_NAME="wipter-config"
STATE_DIR="/var/lib/wipter"
DNS_SERVERS=(94.140.14.15 94.140.15.16)   # AdGuard Family Protection
# Never reachable from the container: RFC 1918, Tailscale CGNAT, link-local, multicast, and
# this-network.
BLOCKED_RANGES=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 224.0.0.0/4 0.0.0.0/8)

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

status "init wipter start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
[ -n "$EMAIL" ] || fail "WIPTER_EMAIL is not set"
[ -n "$PASSWORD" ] || fail "WIPTER_PASSWORD is not set"

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
MEM_AVAIL_MB="$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
LIMIT_MB="$(numfmt --from=iec "${MEMORY_LIMIT^^}" 2>/dev/null | awk '{print int($1/1048576)}' || echo 0)"
if [ "${LIMIT_MB:-0}" -gt 0 ] && [ "${MEM_AVAIL_MB:-0}" -lt "$LIMIT_MB" ] \
   && ! "${DOCKER[@]}" inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  warn "only ${MEM_AVAIL_MB} MB available on the host for a ${MEMORY_LIMIT} cap: other containers may get squeezed"
fi
ok "docker ready (arch ${ARCH}, root on ${MEDIA}, ${MEM_AVAIL_MB} MB available)"

# ---------------------------------------------------------------------------
# 2. Own network + DNS lock
# ---------------------------------------------------------------------------
step "preparing network ${NETWORK_NAME}"
if ! "${DOCKER[@]}" network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  "${DOCKER[@]}" network create --driver bridge --subnet "$NETWORK_SUBNET" \
    -o com.docker.network.bridge.name=br-wipter "$NETWORK_NAME" >/dev/null \
    || fail "failed to create ${NETWORK_NAME} (subnet ${NETWORK_SUBNET} may clash with another network)"
fi
HAVE_SUBNET="$("${DOCKER[@]}" network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME")"
[ "$HAVE_SUBNET" = "$NETWORK_SUBNET" ] || fail "${NETWORK_NAME} exists with another subnet; remove it and re-run"
ok "network ready"

# The rules live in a script + systemd unit, so a reboot (which wipes iptables) gets them back
# as soon as Docker is up. nat: every port-53 packet from the Wipter subnet is sent to the first
# AdGuard server, whatever server the client asked. filter: what is left on 53/853 is only
# allowed towards AdGuard, and anything towards the LAN, Tailscale, link-local or multicast
# ranges is dropped.
step "locking DNS to AdGuard Family Protection and blocking the LAN"
LOCK_SCRIPT="/usr/local/sbin/wipter-dns-lock"
LOCK_UNIT="/etc/systemd/system/wipter-dns-lock.service"
{
  echo '#!/bin/sh'
  echo '# Generated by bash-scripts/init-wipter.sh. Idempotent.'
  echo 'set -e'
  echo "N=${NAT_CHAIN}"
  echo 'iptables -t nat -N "$N" 2>/dev/null || iptables -t nat -F "$N"'
  for p in udp tcp; do
    echo "iptables -t nat -A \"\$N\" -p ${p} --dport 53 -j DNAT --to-destination ${DNS_SERVERS[0]}:53"
  done
  echo "iptables -t nat -C PREROUTING -s ${NETWORK_SUBNET} -j \"\$N\" 2>/dev/null || iptables -t nat -I PREROUTING 1 -s ${NETWORK_SUBNET} -j \"\$N\""
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
  for r in "${BLOCKED_RANGES[@]}"; do
    echo "iptables -A \"\$C\" -d ${r} -j DROP"
  done
  echo 'iptables -N DOCKER-USER 2>/dev/null || true'
  echo "iptables -C DOCKER-USER -s ${NETWORK_SUBNET} -j \"\$C\" 2>/dev/null || iptables -I DOCKER-USER 1 -s ${NETWORK_SUBNET} -j \"\$C\""
} | "${SUDO[@]}" tee "$LOCK_SCRIPT" >/dev/null
"${SUDO[@]}" chmod 755 "$LOCK_SCRIPT"
"${SUDO[@]}" "$LOCK_SCRIPT" || fail "failed to apply the firewall rules"

if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  printf '%s\n' \
    '[Unit]' \
    'Description=Redirect Wipter container DNS to AdGuard Family Protection and block the LAN' \
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
  "${SUDO[@]}" systemctl enable wipter-dns-lock.service >/dev/null 2>&1 \
    || warn "could not enable wipter-dns-lock.service; re-run this script after a reboot"
else
  warn "no systemd: the DNS lock is not re-applied on reboot; re-run this script after one"
fi
ok "DNS redirected to AdGuard, LAN blocked (rules re-applied on boot)"

# A stable machine ID for the app (its device fingerprint), made once on the host.
step "preparing the machine ID"
"${SUDO[@]}" mkdir -p "$STATE_DIR"
if ! "${SUDO[@]}" grep -qxE '[0-9a-f]{32}' "$STATE_DIR/machine-id" 2>/dev/null; then
  od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | "${SUDO[@]}" tee "$STATE_DIR/machine-id" >/dev/null
  echo | "${SUDO[@]}" tee -a "$STATE_DIR/machine-id" >/dev/null
fi
"${SUDO[@]}" chmod 644 "$STATE_DIR/machine-id"
ok "machine ID ready"

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

# The app's profile (session, settings) survives container updates. The volume's root must belong
# to the image's user, whatever made it.
step "preparing the ${VOLUME_NAME} volume"
"${DOCKER[@]}" volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || "${DOCKER[@]}" volume create "$VOLUME_NAME" >/dev/null \
  || fail "failed to create the ${VOLUME_NAME} volume"
"${DOCKER[@]}" run --rm --network none --user 0 --entrypoint chown -v "${VOLUME_NAME}:/v" "$IMAGE" 65532:65532 /v \
  || fail "failed to set the owner of the ${VOLUME_NAME} volume"
ok "volume ready"

# Container log tail with the login, long hex IDs and IPs masked: this repo's logs are
# public.
show_logs() {
  local line
  "${DOCKER[@]}" logs --tail "$1" "$CONTAINER_NAME" 2>&1 \
    | grep -av '^[[:space:]]*$' \
    | sed -E 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<id>/g; s/[0-9A-Fa-f]{24,}/<id>/g; s/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g; s/[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4})*::[0-9A-Fa-f:]*|([0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}/<ipv6>/g' \
    | while IFS= read -r line; do
        line="${line//"$PASSWORD"/<redacted>}"
        printf '%s %s\n' "$2" "${line//"$EMAIL"/<email>}"
      done || true
}

# ---------------------------------------------------------------------------
# 4. Skip the restart when nothing changed
# ---------------------------------------------------------------------------
# A hash of every setting (the login included, never printed) is stored as a label, so an unchanged
# run leaves a healthy container alone instead of reconnecting it.
WANT_SUM="$(printf '%s\n' "$IMAGE_ID" "$EMAIL" "$PASSWORD" "$CPU_LIMIT" "$MEMORY_LIMIT" "$PIDS_LIMIT" "${DNS_SERVERS[*]}" "${BLOCKED_RANGES[*]}" "$NETWORK_NAME" "v1" \
  | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "wipter.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
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
  ok "old container gone"

  step "starting ${CONTAINER_NAME}"
  "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped --init \
    --hostname wipter \
    --network "$NETWORK_NAME" \
    "${DNS_OPTS[@]}" \
    --label "wipter.config=${WANT_SUM}" \
    -e "WIPTER_EMAIL=${EMAIL}" -e "WIPTER_PASSWORD=${PASSWORD}" \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
    --tmpfs /home/nonroot:rw,noexec,nosuid,nodev,size=32m,uid=65532,gid=65532,mode=0700 \
    -v "${VOLUME_NAME}:/home/nonroot/.config" \
    -v "${STATE_DIR}/machine-id:/etc/machine-id:ro" \
    --shm-size 64m \
    --cpus "$CPU_LIMIT" --cpu-shares 256 \
    --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" \
    --oom-score-adj 500 \
    --pids-limit "$PIDS_LIMIT" \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-driver json-file "${LOG_OPTS[@]}" \
    "$IMAGE" >/dev/null \
    || fail "failed to start ${CONTAINER_NAME}"

  # The launcher signs in (or finds the saved session) once the app is up: about a minute on an
  # Orange Pi. It gives up after 3 failed attempts.
  step "waiting for the app to sign in to Wipter"
  SIGNED_IN=0
  for _ in $(seq 1 60); do
    if "${DOCKER[@]}" logs "$CONTAINER_NAME" 2>&1 | grep -q '^wipter-entry: signed in'; then
      SIGNED_IN=1; break
    fi
    "${DOCKER[@]}" logs "$CONTAINER_NAME" 2>&1 | grep -q '^wipter-entry: sign-in failed 3 times' && break
    [ "$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null)" = "running" ] || break
    sleep 5
  done
  if [ "$SIGNED_IN" != "1" ]; then
    show_logs 15 '[!]  ' >&2
    fail "the app did not sign in to Wipter (see the log above)"
  fi
  ok "signed in"
fi

# ---------------------------------------------------------------------------
# 6. Verify: still running and not restart-looping after a short settle
# ---------------------------------------------------------------------------
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
  [ "$OOM" = "true" ] && fail "${CONTAINER_NAME} hit the ${MEMORY_LIMIT} memory cap; raise WIPTER_MEMORY_LIMIT"
  fail "${CONTAINER_NAME} is not staying up (see the log above and builder-tools/wipter/README.md)"
fi
if [ "${RESTARTS:-0}" -gt 0 ]; then
  LAST_EXIT="$("${DOCKER[@]}" inspect -f '{{.State.ExitCode}}' "$CONTAINER_NAME" 2>/dev/null || echo '?')"
  warn "${CONTAINER_NAME} restarted ${RESTARTS} time(s) since it was created (oom: ${OOM}, last exit code: ${LAST_EXIT}); stable during the check"
fi

# DNS: the container must use exactly the AdGuard servers, and the redirect and lock must be in
# place
step "verifying DNS redirect, DNS lock and LAN block"
HAVE_DNS="$("${DOCKER[@]}" inspect -f '{{join .HostConfig.Dns " "}}' "$CONTAINER_NAME")"
[ "$HAVE_DNS" = "${DNS_SERVERS[*]}" ] || fail "container DNS is not AdGuard Family Protection"
RESOLV="$("${DOCKER[@]}" inspect -f '{{.ResolvConfPath}}' "$CONTAINER_NAME")"
NS="$("${SUDO[@]}" grep -E '^nameserver' "$RESOLV" | awk '{print $2}' | paste -sd' ' -)"
[ "$NS" = "127.0.0.11" ] || [ "$NS" = "${DNS_SERVERS[*]}" ] || fail "unexpected nameserver in the container's resolv.conf"
"${SUDO[@]}" iptables -t nat -C PREROUTING -s "$NETWORK_SUBNET" -j "$NAT_CHAIN" 2>/dev/null \
  || fail "DNS redirect rule is missing from nat PREROUTING"
"${SUDO[@]}" iptables -C DOCKER-USER -s "$NETWORK_SUBNET" -j "$FW_CHAIN" 2>/dev/null \
  || fail "DNS firewall rule is missing from DOCKER-USER"
"${SUDO[@]}" iptables -C "$FW_CHAIN" -d 192.168.0.0/16 -j DROP 2>/dev/null \
  || fail "LAN block rule is missing from ${FW_CHAIN}"
"${SUDO[@]}" iptables -C "$FW_CHAIN" -d 224.0.0.0/4 -j DROP 2>/dev/null \
  || fail "multicast block rule is missing from ${FW_CHAIN}"
ok "DNS: every query goes to AdGuard Family Protection; LAN and multicast unreachable"
[ "${INIT_DEBUG:-0}" = "1" ] && show_logs 10 '[d]  '
ok "${CONTAINER_NAME} is up"

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE}"
echo "[*] limits: cpu ${CPU_LIMIT}, memory ${MEMORY_LIMIT} (no swap), pids ${PIDS_LIMIT}"
echo "[*] dns: AdGuard Family Protection (all port-53 traffic redirected)"
echo "[*] lan: blocked (private, Tailscale, link-local, multicast)"
echo "[*] memory: ${MEM:-unknown}"
STATUS="$("${DOCKER[@]}" logs "$CONTAINER_NAME" 2>&1 | grep -a '^wipter-entry: status: ' | tail -n 1 | sed 's/^wipter-entry: status: //')"
echo "[*] app status: ${STATUS:-not shown yet}"
ok "init wipter done"

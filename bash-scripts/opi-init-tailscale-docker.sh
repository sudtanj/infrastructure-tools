#!/bin/bash
# bash-scripts/opi-init-tailscale-docker.sh
# Idempotent deploy of Tailscale as a read-only distroless container (sudtanj/tailscale, built from
# builder-tools/tailscale/). Made for an Orange Pi Zero 3 (arm64, Armbian/Debian, SD card) and
# works on any Linux with Docker. Requires docker; curl only for OPI_TS_IP / route approval.
#
# Host network, kernel mode: tailscaled creates a real tailscale0 on the host, exactly like a host
# install. The host and every other container reach the tailnet through it with no extra setup,
# and services published on the host answer on the Tailscale IP. The LocalAPI socket is the
# host's /run/tailscale/tailscaled.sock, so a host `tailscale` CLI (tailscale ip -4, status, set)
# keeps working; without one, a /usr/local/bin/tailscale wrapper runs the CLI in the container.
#
# Read-only: the image filesystem is mounted read-only and the config file read-only. The only
# writable paths are /tmp (tmpfs, 16 MB), the node state directory (node key and prefs; tailscaled
# can't run without it) and the LocalAPI socket directory.
#
# By default the node advertises itself as an exit node; OPI_TS_ROUTES adds subnet routes.
#
# Auth: TAILSCALE_OAUTH_CLIENT_SECRET, the same OAuth client the GitHub workflows here use, is the
# only credential. A new node logs in with a one-off, non-ephemeral, pre-approved auth key minted
# from it and tagged OPI_TS_TAGS. The same client approves the routes and the exit node, and
# moves the node to OPI_TS_IP (Tailscale assigns IPs on its side, so pinning one goes through the
# API).
#
# Taking over a host-installed tailscaled (OPI_TS_MIGRATE=1, the default): the host service is
# stopped and masked, its node identity is copied into the container's state, so the tailnet IP,
# name and tags stay the same. The switch runs as its own systemd unit, so it finishes even when
# this script came in over SSH through that same tailnet. If the container does not come up, the
# host tailscaled is restored. A stopped host install is reused the same way: its node identity
# is copied in (also over a container node that got logged out), so the machine keeps its IP.
#
# Env:
#   TAILSCALE_OAUTH_CLIENT_SECRET  OAuth client secret (tskey-client-...). Scopes: auth_keys to log
#                       a new node in, devices:core for OPI_TS_IP, devices:routes for route
#                       approval. Not needed to take over a host install or once logged in;
#                       without it, approve routes in the admin console and OPI_TS_IP is ignored.
#                       The minted key is removed from disk after the login.
#   OPI_TS_TAGS         tags for this node, comma separated, e.g. tag:opi. Used for the first login
#                       and kept in sync on every run (devices:core). The OAuth client must own them.
#   OPI_TS_HOSTNAME     node name (default: the host name)
#   OPI_TS_IP           tailnet IPv4 for this node, e.g. 100.100.10.10. Changing it drops
#                       connections to the old IP, this SSH session included, so it is the very
#                       last step.
#   OPI_TS_ROUTES       subnet routes to advertise, comma separated, e.g. 192.168.1.0/24
#   OPI_TS_EXIT_NODE    1 (default) = advertise as exit node | 0
#   OPI_TS_PORT         WireGuard UDP port (default 41641)
#   OPI_TS_IMAGE        default sudtanj/tailscale:latest
#   OPI_TS_MEMORY_LIMIT default 128m (the Go heap target is 3/4 of it)
#   OPI_TS_MIGRATE      1 (default) = take over a running host tailscaled | 0 = stop instead
#   OPI_TS_HOST_STATE   host state file to take over (default /var/lib/tailscale/tailscaled.state)

set -euo pipefail

CONTAINER_NAME="tailscale"
ROOT="/var/lib/tailscale-docker"
HELPER="${ROOT}/tailscale-docker"
IMAGE="${OPI_TS_IMAGE:-sudtanj/tailscale:latest}"
TS_HOST="${OPI_TS_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
WANT_IP="$(printf '%s' "${OPI_TS_IP:-}" | tr -d '[:space:]')"
ROUTES_RAW="$(printf '%s' "${OPI_TS_ROUTES:-}" | tr -d '[:space:]')"
EXIT_NODE="${OPI_TS_EXIT_NODE:-1}"
OAUTH_SECRET="$(printf '%s' "${TAILSCALE_OAUTH_CLIENT_SECRET:-}" | tr -d '[:space:]')"
TAGS_RAW="$(printf '%s' "${OPI_TS_TAGS:-}" | tr -d '[:space:]')"
PORT="${OPI_TS_PORT:-41641}"
MEMORY_LIMIT="${OPI_TS_MEMORY_LIMIT:-128m}"
MIGRATE="${OPI_TS_MIGRATE:-1}"
HOST_STATE="${OPI_TS_HOST_STATE:-/var/lib/tailscale/tailscaled.state}"
SYSCTL_CONF="/etc/sysctl.d/99-tailscale.conf"
API="https://api.tailscale.com/api/v2"

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

# Write stdin to a root-owned file only when the content differs; returns 1 when unchanged.
# Writes in place (same inode), so a file bind-mounted into the container stays the same file.
put() {
  local file="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if "${SUDO[@]}" cmp -s "$tmp" "$file" 2>/dev/null; then rm -f "$tmp"; return 1; fi
  "${SUDO[@]}" touch "$file"
  "${SUDO[@]}" chmod "$mode" "$file"
  "${SUDO[@]}" tee "$file" < "$tmp" >/dev/null
  rm -f "$tmp"
}

renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

status "init tailscale-docker start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"
DOCKER_INFO="$("${DOCKER[@]}" info --format '{{json .}}' 2>/dev/null)" || fail "docker daemon is not available"
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "OPI_TS_PORT must be 1-65535"
[[ "$MEMORY_LIMIT" =~ ^[0-9]+[mMgG]$ ]] || fail "OPI_TS_MEMORY_LIMIT must look like 128m or 1g"
[[ "$TS_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || fail "OPI_TS_HOSTNAME must be letters, digits and dashes"
[[ "$IMAGE" =~ ^[A-Za-z0-9./:@_-]+$ ]] || fail "OPI_TS_IMAGE has unexpected characters"
for v in EXIT_NODE MIGRATE; do
  case "${!v}" in 0|1) ;; *) fail "OPI_TS_${v} must be 0 or 1" ;; esac
done

# Tailnet IPs come from 100.64.0.0/10 (100.64.x.x - 100.127.x.x)
if [ -n "$WANT_IP" ]; then
  [[ "$WANT_IP" =~ ^100\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
    && [ "${BASH_REMATCH[1]}" -ge 64 ] && [ "${BASH_REMATCH[1]}" -le 127 ] \
    && [ "${BASH_REMATCH[2]}" -le 255 ] && [ "${BASH_REMATCH[3]}" -le 255 ] \
    || fail "OPI_TS_IP must be an IPv4 in 100.64.0.0/10 (100.64.x.x - 100.127.x.x)"
fi

# Subnet routes -> JSON list. Plain shape checks; tailscaled rejects anything else on start.
ROUTES=()
if [ -n "$ROUTES_RAW" ]; then
  IFS=',' read -ra ROUTES <<< "$ROUTES_RAW"
  for r in "${ROUTES[@]}"; do
    [[ "$r" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ || "$r" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] \
      || fail "OPI_TS_ROUTES: '${r}' is not a CIDR like 192.168.1.0/24"
  done
fi
json_list() { local out="" x; for x in "$@"; do out="${out:+${out}, }\"${x}\""; done; printf '[%s]' "$out"; }

TAGS=()
if [ -n "$TAGS_RAW" ]; then
  IFS=',' read -ra TAGS <<< "$TAGS_RAW"
  for t in "${TAGS[@]}"; do
    [[ "$t" =~ ^tag:[A-Za-z0-9_-]+$ ]] || fail "OPI_TS_TAGS: '${t}' is not a tag like tag:server"
  done
fi

if [ -n "$OAUTH_SECRET" ]; then
  [[ "$OAUTH_SECRET" =~ ^tskey-client-[A-Za-z0-9-]+$ ]] || fail "TAILSCALE_OAUTH_CLIENT_SECRET must be an OAuth client secret (tskey-client-...)"
  command -v curl >/dev/null 2>&1 || fail "curl is needed for the Tailscale API (apt-get install curl)"
elif [ -n "$WANT_IP" ]; then
  warn "OPI_TS_IP is set but there is no TAILSCALE_OAUTH_CLIENT_SECRET: the IP can only be set through the Tailscale API, skipping it"
fi

# Tailscale API. The bearer token sits in a 0600 temp file passed as `-H @file`, never in argv
# (visible in ps).
API_HDR=""
cleanup() { [ -n "$API_HDR" ] && rm -f "$API_HDR"; }
trap cleanup EXIT

api_login() {
  [ -n "$API_HDR" ] && return 0
  [ -n "$OAUTH_SECRET" ] || return 1
  # OAuth client secret (tskey-client-<client id>-<secret>) -> short-lived access token
  local token cid="${OAUTH_SECRET#tskey-client-}"
  cid="${cid%%-*}"
  token="$(printf 'client_id=%s&client_secret=%s' "$cid" "$OAUTH_SECRET" \
    | curl -fsS -m 20 -d @- "${API}/oauth/token" 2>/dev/null \
    | sed -n 's/.*"access_token" *: *"\([^"]*\)".*/\1/p')" || true
  [ -n "$token" ] || return 1
  API_HDR="$(mktemp)"
  chmod 600 "$API_HDR"
  printf 'Authorization: Bearer %s\n' "$token" > "$API_HDR"
}
api_call() { # path json -> response body
  curl -fsS -m 30 -X POST -H @"$API_HDR" -H 'Content-Type: application/json' \
    --data-binary "$2" "${API}$1" 2>/dev/null
}
# Like api_call, but keeps the body to itself and leaves "HTTP <code>: <API message>" in API_ERR
API_ERR=""
api_post() { # path json
  local out code msg
  out="$(curl -sS -m 30 -X POST -H @"$API_HDR" -H 'Content-Type: application/json' \
    --data-binary "$2" -w '\n%{http_code}' "${API}$1" 2>/dev/null)" || true
  code="${out##*$'\n'}"
  [[ "$code" =~ ^[0-9]{3}$ ]] || { API_ERR="no answer from the Tailscale API"; return 1; }
  [[ "$code" == 2?? ]] && return 0
  msg="$(printf '%s' "${out%$'\n'*}" | sed -n 's/.*"message" *: *"\([^"]*\)".*/\1/p' | head -c 200)"
  API_ERR="HTTP ${code}${msg:+: ${msg}}"
  return 1
}

# One-off auth key from the OAuth client: single use, not ephemeral (the node must survive
# restarts), pre-approved, tagged (an OAuth client can only create tagged keys), valid 1 hour.
mint_authkey() {
  api_login || return 1
  api_call "/tailnet/-/keys" "{\"capabilities\": {\"devices\": {\"create\": {\"reusable\": false, \"ephemeral\": false, \"preauthorized\": true, \"tags\": $(json_list "${TAGS[@]}")}}}, \"expirySeconds\": 3600, \"description\": \"opi-init-tailscale-docker\"}" \
    | sed -n 's/.*"key" *: *"\(tskey-[^"]*\)".*/\1/p'
}

HAS_SYSTEMD=0
[ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && HAS_SYSTEMD=1

if [ ! -c /dev/net/tun ]; then
  "${SUDO[@]}" modprobe tun >/dev/null 2>&1 || true
  [ -c /dev/net/tun ] || fail "/dev/net/tun is missing and 'modprobe tun' did not create it"
fi
# Best effort: tailscaled programs nftables over netlink, the image has no iptables
"${SUDO[@]}" modprobe nf_tables >/dev/null 2>&1 || true

# Resource caps, each only where the kernel supports it
has() { printf '%s' "$DOCKER_INFO" | grep -q "\"$1\":true"; }
LIMITS=""
if has MemoryLimit; then
  LIMITS="--memory ${MEMORY_LIMIT}"
  has SwapLimit && LIMITS="${LIMITS} --memory-swap ${MEMORY_LIMIT}"
fi
has PidsLimit && LIMITS="${LIMITS:+${LIMITS} }--pids-limit 64"
MEM_MIB="${MEMORY_LIMIT%?}"
case "$MEMORY_LIMIT" in *[gG]) MEM_MIB=$(( MEM_MIB * 1024 )) ;; esac
GO_MEM_LIMIT="$(( MEM_MIB * 3 / 4 ))MiB"

# SD/eMMC root: keep container logs tiny to limit flash wear
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
if [[ "$ROOT_SRC" == /dev/mmcblk* ]]; then
  LOG_OPTS="--log-opt max-size=1m --log-opt max-file=1"
  MEDIA="sd/emmc"
else
  LOG_OPTS="--log-opt max-size=5m --log-opt max-file=2"
  MEDIA="disk"
fi
ok "docker ready (arch $(uname -m), root on ${MEDIA}, caps: ${LIMITS:-none supported})"

# ---------------------------------------------------------------------------
# 2. Image
# ---------------------------------------------------------------------------
step "pulling ${IMAGE}"
PULLED=0
for attempt in 1 2 3; do
  if "${DOCKER[@]}" pull -q "$IMAGE" >/dev/null 2>&1; then PULLED=1; break; fi
  warn "pull failed (attempt ${attempt}/3)"
  [ "$attempt" -lt 3 ] && sleep $(( attempt * 5 ))
done
if [ "$PULLED" != "1" ]; then
  # A running container keeps the box reachable; never take it down over a failed pull
  "${DOCKER[@]}" image inspect "$IMAGE" >/dev/null 2>&1 || fail "failed to pull ${IMAGE}; check DNS/IPv6 access to Docker Hub"
  warn "using the image already on this host"
fi
ok "image ready"

# ---------------------------------------------------------------------------
# 3. Host tailscaled: take over, refuse, or nothing to do
# ---------------------------------------------------------------------------
HOST_ACTIVE=0
if [ "$HAS_SYSTEMD" = 1 ]; then
  systemctl is-active --quiet tailscaled 2>/dev/null && HOST_ACTIVE=1
else
  RUNNING_CTR="$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
  [ "$RUNNING_CTR" != "true" ] && pgrep -x tailscaled >/dev/null 2>&1 && HOST_ACTIVE=1
fi
if [ "$HOST_ACTIVE" = 1 ]; then
  [ "$MIGRATE" = 1 ] || fail "a host tailscaled is running; stop it or set OPI_TS_MIGRATE=1"
  [ "$HAS_SYSTEMD" = 1 ] || fail "a host tailscaled is running outside systemd; stop it first"
  ok "host tailscaled found: it will be taken over"
fi

# ---------------------------------------------------------------------------
# 4. Settings and tailscaled config
# ---------------------------------------------------------------------------
step "writing settings to ${ROOT}"
"${SUDO[@]}" mkdir -p "${ROOT}/state"
"${SUDO[@]}" chmod 700 "$ROOT" "${ROOT}/state"

HAVE_STATE=0
"${SUDO[@]}" test -s "${ROOT}/state/tailscaled.state" && HAVE_STATE=1
[ "$HOST_ACTIVE" = 1 ] && "${SUDO[@]}" test -s "$HOST_STATE" && HAVE_STATE=1

# A stopped host install still has its node identity on disk. Reusing it keeps the machine as it
# was (same tailnet IP, name, tags, approved routes, key expiry setting): no new node, no new IP.
HOST_IDLE_STATE=0
ADOPTED=0
[ "$HOST_ACTIVE" = 0 ] && "${SUDO[@]}" test -s "$HOST_STATE" && HOST_IDLE_STATE=1
adopt_host_state() {
  "${SUDO[@]}" cp -p "$HOST_STATE" "${ROOT}/state/tailscaled.state"
  "${SUDO[@]}" chmod 600 "${ROOT}/state/tailscaled.state"
  ADOPTED=1
}
if [ "$HAVE_STATE" = 0 ] && [ "$HOST_IDLE_STATE" = 1 ]; then
  adopt_host_state
  HAVE_STATE=1
  ok "reusing the stopped host install's node identity (same tailnet IP, name and tags)"
fi

# Login key, only for a new node: minted from the OAuth client
AUTHKEY=""
if [ "$HAVE_STATE" = 0 ] && [ -n "$OAUTH_SECRET" ]; then
  if [ "${#TAGS[@]}" -eq 0 ]; then
    warn "OPI_TS_TAGS is empty: an OAuth client can only create tagged keys, so it can't log this node in"
  else
    AUTHKEY="$(mint_authkey || true)"
    if [ -n "$AUTHKEY" ]; then
      ok "one-off auth key created from the OAuth client (tags: ${TAGS_RAW})"
    else
      warn "could not create an auth key from the OAuth client (it needs the auth_keys scope and must own ${TAGS_RAW})"
    fi
  fi
fi
[ -z "$AUTHKEY" ] || [[ "$AUTHKEY" =~ ^tskey-auth-[A-Za-z0-9-]+$ ]] || fail "the minted auth key does not look like tskey-auth-..."

# The key goes on disk only for the first login and is removed once the node is logged in
config() {
  printf '{\n  "Version": "alpha0",\n  "Locked": false,\n'
  [ "${1:-}" = "with-key" ] && printf '  "AuthKey": "%s",\n' "$AUTHKEY"
  printf '  "Hostname": "%s",\n' "$TS_HOST"
  printf '  "AdvertiseExitNode": %s,\n' "$([ "$EXIT_NODE" = 1 ] && echo true || echo false)"
  printf '  "AdvertiseRoutes": %s,\n' "$(json_list "${ROUTES[@]}")"
  # Other subnet routers' routes never override the LAN; the host resolver is left alone
  printf '  "acceptRoutes": false,\n  "acceptDNS": false\n}\n'
}
NEED_LOGIN=0
if [ "$HAVE_STATE" = 0 ]; then
  NEED_LOGIN=1
  if [ -n "$AUTHKEY" ]; then
    config with-key | put "${ROOT}/tailscaled.json" 600 || true
  else
    warn "no node state and no login key from TAILSCALE_OAUTH_CLIENT_SECRET: the container starts logged out"
    config | put "${ROOT}/tailscaled.json" 600 || true
  fi
else
  config | put "${ROOT}/tailscaled.json" 600 || true
fi

put "${ROOT}/settings" 600 <<EOF || true
# Written by opi-init-tailscale-docker.sh; rerun it instead of editing this file.
IMAGE=$(printf '%q' "$IMAGE")
CONTAINER=$(printf '%q' "$CONTAINER_NAME")
PORT=$(printf '%q' "$PORT")
LIMITS=$(printf '%q' "$LIMITS")
LOG_OPTS=$(printf '%q' "$LOG_OPTS")
GO_MEM_LIMIT=$(printf '%q' "$GO_MEM_LIMIT")
HOST_STATE=$(printf '%q' "$HOST_STATE")
EOF

# Helper shared by this script and the takeover unit, so both create the container with the same
# flags.
put "$HELPER" 700 <<'HELPER_EOF' || true
#!/bin/bash
# Written by bash-scripts/opi-init-tailscale-docker.sh; rerun that script instead of editing this file.
# Usage: tailscale-docker start | state | wait [Running] | spec | cutover
set -euo pipefail
ROOT=/var/lib/tailscale-docker
. "$ROOT/settings"
log() { printf '%s\n' "[tailscale-docker] $*"; }

lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>"$ROOT/lock"
  flock -w 600 9 || { log "another run holds the lock"; exit 1; }
}

# Identity of a deployment: settings, config (without the one-time auth key) and image
spec() {
  { cat "$ROOT/settings"; grep -v '"AuthKey"' "$ROOT/tailscaled.json"; docker image inspect -f '{{.Id}}' "$IMAGE"; } \
    | sha256sum | cut -c1-16
}

# Read-only image filesystem and config; writable: /tmp (tmpfs), node state, LocalAPI socket dir
start() {
  local s
  s="$(spec)"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  # LIMITS and LOG_OPTS are word lists on purpose
  # shellcheck disable=SC2086
  docker run -d --name "$CONTAINER" \
    --label "tailscale-docker.spec=${s}" \
    --restart unless-stopped \
    --network host \
    --device /dev/net/tun:/dev/net/tun \
    --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW \
    --security-opt no-new-privileges \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
    -v "$ROOT/state:/var/lib/tailscale" \
    -v /run/tailscale:/var/run/tailscale \
    -v "$ROOT/tailscaled.json:/etc/tailscale/tailscaled.json:ro" \
    --oom-score-adj -500 --cpu-shares 512 $LIMITS \
    --log-driver json-file $LOG_OPTS \
    -e GOMEMLIMIT="$GO_MEM_LIMIT" \
    "$IMAGE" --config=/etc/tailscale/tailscaled.json --port="$PORT" >/dev/null
}

state() {
  docker exec "$CONTAINER" tailscale status --json --peers=false 2>/dev/null \
    | sed -n 's/^ *"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -n1 || true
}

# Ready = backend Running; when Running is not required, any settled state (e.g. NeedsLogin)
wait_ready() {
  local want="${1:-}" st s
  for _ in $(seq 1 45); do
    st="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
    if [ "$st" = running ]; then
      s="$(state)"
      [ "$s" = Running ] && return 0
      if [ "$want" != Running ] && [ -n "$s" ] && [ "$s" != NoState ] && [ "$s" != Starting ]; then return 0; fi
    fi
    sleep 2
  done
  return 1
}

# Take over from a host tailscaled. Runs as its own systemd unit: the SSH session that started it
# may ride on the tailnet this replaces.
cutover() {
  local result="$ROOT/cutover.result" copied=0 want=""
  rm -f "$result"
  log "stopping the host tailscaled"
  systemctl disable --now tailscaled >/dev/null 2>&1 || systemctl stop tailscaled >/dev/null 2>&1 || true
  # Masked, so a later host install (init-tailscale.sh) can't start a second tailscaled
  systemctl mask tailscaled >/dev/null 2>&1 || true
  if [ ! -s "$ROOT/state/tailscaled.state" ] && [ -s "$HOST_STATE" ]; then
    cp -p "$HOST_STATE" "$ROOT/state/tailscaled.state"
    chmod 600 "$ROOT/state/tailscaled.state"
    copied=1
    log "copied the host node identity"
  fi
  [ -s "$ROOT/state/tailscaled.state" ] && want=Running
  if start && wait_ready "$want"; then
    # The old file would be a second copy of the same node key
    [ -s "$HOST_STATE" ] && mv -f "$HOST_STATE" "${HOST_STATE}.moved-to-docker"
    echo ok > "$result"
    log "takeover done, backend $(state)"
    return 0
  fi
  log "container did not come up, restoring the host tailscaled"
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ "$copied" = 1 ] && rm -f "$ROOT/state/tailscaled.state"
  systemctl unmask tailscaled >/dev/null 2>&1 || true
  systemctl enable --now tailscaled >/dev/null 2>&1 || systemctl start tailscaled >/dev/null 2>&1 || true
  echo failed > "$result"
  return 1
}

case "${1:-}" in
  start)   lock; start ;;
  state)   state ;;
  wait)    wait_ready "${2:-}" ;;
  spec)    spec ;;
  cutover) lock; cutover ;;
  *) echo "usage: $0 start | state | wait [Running] | spec | cutover" >&2; exit 2 ;;
esac
HELPER_EOF
ok "settings ready (config mode 600, auth key $([ "$NEED_LOGIN" = 1 ] && [ -n "$AUTHKEY" ] && echo "stored for the first login" || echo "not stored"))"

# ---------------------------------------------------------------------------
# 5. IP forwarding (exit node / subnet router)
# ---------------------------------------------------------------------------
# Docker can't set net.* sysctls for a host-network container, so the host does it.
# IPv6 forwarding=1 makes the kernel ignore router advertisements on interfaces with accept_ra=1,
# dropping the IPv6 default route, so those interfaces are switched to accept_ra=2 first.
if [ "$EXIT_NODE" = 1 ] || [ "${#ROUTES[@]}" -gt 0 ]; then
  IFACE=$(ip -o route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' || true)
  [ -z "$IFACE" ] && IFACE=$(ip -o -6 route get 2001:4860:4860::8888 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' || true)
  WANT_SYSCTL=""
  for k in default ${IFACE:+"$IFACE"}; do
    if [ "$(sysctl -n "net.ipv6.conf.${k}.accept_ra" 2>/dev/null || true)" = "1" ] \
       || grep -qx "net.ipv6.conf.${k}.accept_ra = 2" "$SYSCTL_CONF" 2>/dev/null; then
      WANT_SYSCTL+="net.ipv6.conf.${k}.accept_ra = 2"$'\n'
    fi
  done
  WANT_SYSCTL+="net.ipv4.ip_forward = 1"$'\n'
  [ -e /proc/sys/net/ipv6/conf/all/forwarding ] && WANT_SYSCTL+="net.ipv6.conf.all.forwarding = 1"$'\n'
  "${SUDO[@]}" mkdir -p "$(dirname "$SYSCTL_CONF")"
  printf '%s' "$WANT_SYSCTL" | put "$SYSCTL_CONF" 644 && step "wrote ${SYSCTL_CONF}"
  if "${SUDO[@]}" sysctl -q -p "$SYSCTL_CONF" >/dev/null 2>&1; then
    ok "IP forwarding on"
  else
    warn "could not apply ${SYSCTL_CONF}; exit node and subnet routes will not forward"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Container
# ---------------------------------------------------------------------------
WANT_READY=""
# Saved state that is logged out on the server settles in NeedsLogin; that is handled below
[ -n "$AUTHKEY" ] && WANT_READY=Running
OLD_IMAGE_ID="$("${DOCKER[@]}" inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"

if [ "$HOST_ACTIVE" = 1 ]; then
  step "taking over from the host tailscaled"
  warn "an SSH session over Tailscale may pause for 10-60 s; the switch runs on its own and is not affected"
  "${SUDO[@]}" rm -f "${ROOT}/cutover.result"
  "${SUDO[@]}" systemd-run --quiet --collect --unit "tailscale-docker-cutover-$(date +%s)" \
    /bin/bash "$HELPER" cutover || fail "could not start the takeover unit"
  RESULT=""
  for _ in $(seq 1 75); do
    RESULT="$("${SUDO[@]}" cat "${ROOT}/cutover.result" 2>/dev/null || true)"
    [ -n "$RESULT" ] && break
    sleep 2
  done
  case "$RESULT" in
    ok)     ok "takeover done; the host tailscaled is masked" ;;
    failed) fail "the container did not come up; the host tailscaled was restored (journalctl -u 'tailscale-docker-cutover-*')" ;;
    *)      fail "takeover still running; rerun this script to see the result" ;;
  esac
else
  CURRENT_SPEC="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "tailscale-docker.spec"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  RUNNING="$("${DOCKER[@]}" inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
  WANT_SPEC="$("${SUDO[@]}" bash "$HELPER" spec)"
  if [ "$RUNNING" = "true" ] && [ "$CURRENT_SPEC" = "$WANT_SPEC" ]; then
    ok "container unchanged"
  else
    step "starting ${CONTAINER_NAME}"
    "${SUDO[@]}" bash "$HELPER" start || fail "failed to start ${CONTAINER_NAME}"
  fi
  step "waiting for tailscaled"
  if ! "${SUDO[@]}" bash "$HELPER" wait "$WANT_READY"; then
    "${DOCKER[@]}" logs --tail 20 "$CONTAINER_NAME" 2>&1 | sed 's/^/[!]   /' >&2 || true
    fail "tailscaled did not become ready"
  fi
fi

BACKEND="$("${SUDO[@]}" bash "$HELPER" state 2>/dev/null || true)"

# Saved state but logged out on the server (machine deleted in the admin console, key revoked):
# log in again with a fresh key from the OAuth client. tailscaled reads the key from its config
# at start, and put() rewrites the bind-mounted file in place, so a restart is enough.
# First choice: the stopped host install's identity, which keeps its IP. The logged-out container
# state is kept next to it, and put back if the host identity doesn't log in either.
if [ "$BACKEND" = "NeedsLogin" ] && [ -z "$AUTHKEY" ] && [ "$HOST_IDLE_STATE" = 1 ] && [ "$ADOPTED" = 0 ]; then
  warn "the container's node is logged out on the server; switching to the host install's node identity"
  LOGGED_OUT="${ROOT}/state/tailscaled.state.logged-out-$(date +%s)"
  "${DOCKER[@]}" stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "${SUDO[@]}" mv -f "${ROOT}/state/tailscaled.state" "$LOGGED_OUT"
  adopt_host_state
  "${DOCKER[@]}" start "$CONTAINER_NAME" >/dev/null || fail "failed to start ${CONTAINER_NAME}"
  if "${SUDO[@]}" bash "$HELPER" wait Running; then
    ok "back on the host install's node (same tailnet IP, name and tags)"
  else
    warn "the host install's node identity is logged out too; going back to the container's"
    "${DOCKER[@]}" stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    "${SUDO[@]}" mv -f "$LOGGED_OUT" "${ROOT}/state/tailscaled.state"
    ADOPTED=0
    "${DOCKER[@]}" start "$CONTAINER_NAME" >/dev/null || fail "failed to start ${CONTAINER_NAME}"
    "${SUDO[@]}" bash "$HELPER" wait || true
  fi
  BACKEND="$("${SUDO[@]}" bash "$HELPER" state 2>/dev/null || true)"
fi

if [ "$BACKEND" = "NeedsLogin" ] && [ -z "$AUTHKEY" ] && [ -n "$OAUTH_SECRET" ]; then
  warn "node state is there but Tailscale wants a new login (was the machine removed from the admin console?)"
  if [ "${#TAGS[@]}" -eq 0 ]; then
    warn "OPI_TS_TAGS is empty: an OAuth client can only create tagged keys, so it can't log this node in"
  else
    AUTHKEY="$(mint_authkey || true)"
    if [ -z "$AUTHKEY" ]; then
      warn "could not create an auth key from the OAuth client (it needs the auth_keys scope and must own ${TAGS_RAW})"
    elif ! [[ "$AUTHKEY" =~ ^tskey-auth-[A-Za-z0-9-]+$ ]]; then
      fail "the minted auth key does not look like tskey-auth-..."
    else
      ok "one-off auth key created from the OAuth client (tags: ${TAGS_RAW})"
      config with-key | put "${ROOT}/tailscaled.json" 600 || true
      step "restarting ${CONTAINER_NAME} to log in"
      "${DOCKER[@]}" restart "$CONTAINER_NAME" >/dev/null || fail "failed to restart ${CONTAINER_NAME}"
      if ! "${SUDO[@]}" bash "$HELPER" wait Running; then
        "${DOCKER[@]}" logs --tail 20 "$CONTAINER_NAME" 2>&1 | sed 's/^/[!]   /' >&2 || true
        config | put "${ROOT}/tailscaled.json" 600 || true
        fail "tailscaled did not log in with the new key"
      fi
      BACKEND="$("${SUDO[@]}" bash "$HELPER" state 2>/dev/null || true)"
    fi
  fi
fi

if [ "$BACKEND" = "Running" ] && [ "$ADOPTED" = 1 ]; then
  # The old file would be a second copy of the same node key; a host tailscaled started at boot
  # would fight the container for tailscale0
  "${SUDO[@]}" mv -f "$HOST_STATE" "${HOST_STATE}.moved-to-docker" || true
  if [ "$HAS_SYSTEMD" = 1 ] && systemctl cat tailscaled >/dev/null 2>&1; then
    "${SUDO[@]}" systemctl disable tailscaled >/dev/null 2>&1 || true
    "${SUDO[@]}" systemctl mask tailscaled >/dev/null 2>&1 || true
  fi
  ok "host install retired (state renamed to $(basename "$HOST_STATE").moved-to-docker, service masked)"
fi
if [ "$BACKEND" = "Running" ] && "${SUDO[@]}" grep -q '"AuthKey"' "${ROOT}/tailscaled.json"; then
  config | put "${ROOT}/tailscaled.json" 600 && ok "auth key removed from disk (node is logged in)"
fi
NEW_IMAGE_ID="$("${DOCKER[@]}" inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
if [ -n "$OLD_IMAGE_ID" ] && [ -n "$NEW_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
  "${DOCKER[@]}" rmi "$OLD_IMAGE_ID" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 7. Host CLI
# ---------------------------------------------------------------------------
# A host `tailscale` binary talks to the container through /run/tailscale/tailscaled.sock.
# Without one, a wrapper runs the CLI inside the container (skipped on read-only /usr/local).
if ! command -v tailscale >/dev/null 2>&1; then
  if printf '%s\n' '#!/bin/sh' \
       '# Written by opi-init-tailscale-docker.sh: the Tailscale CLI inside the tailscale container.' \
       'if [ "$(id -u)" -eq 0 ]; then exec docker exec -i tailscale tailscale "$@"; fi' \
       'exec sudo docker exec -i tailscale tailscale "$@"' \
       | put /usr/local/bin/tailscale 755 2>/dev/null; then
    ok "installed /usr/local/bin/tailscale (runs the CLI in the container)"
  fi
fi

# ---------------------------------------------------------------------------
# 8. Tailscale API: approve routes, pin the IP
# ---------------------------------------------------------------------------
ts_ip4() { "${DOCKER[@]}" exec "$CONTAINER_NAME" tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true; }

IP_RESULT="unchanged"
ROUTES_RESULT="$([ "$EXIT_NODE" = 1 ] || [ "${#ROUTES[@]}" -gt 0 ] && echo "approve in the admin console (Machines -> Edit route settings)" || echo "none")"
if [ -n "$OAUTH_SECRET" ] && [ "$BACKEND" = "Running" ]; then
  step "Tailscale API"
  # Self.ID (the API's nodeId) is the only quoted "ID" in status --json --peers=false
  NODE_ID="$("${DOCKER[@]}" exec "$CONTAINER_NAME" tailscale status --json --peers=false 2>/dev/null \
    | sed -n 's/^ *"ID": *"\([^"]*\)".*/\1/p' | head -n1 || true)"
  if [ -z "$NODE_ID" ]; then
    warn "could not read this node's ID; skipping the API steps"
  elif ! api_login; then
    warn "Tailscale API login failed (check TAILSCALE_OAUTH_CLIENT_SECRET); skipping the API steps"
  else
    # A login key only tags a node at its first login, so later OPI_TS_TAGS changes go through the API
    if [ "${#TAGS[@]}" -gt 0 ]; then
      sorted() { tr ',' '\n' | sort -u | paste -sd, -; }
      CUR_TAGS="$("${DOCKER[@]}" exec "$CONTAINER_NAME" tailscale status --json --peers=false 2>/dev/null \
        | tr -d ' \t\n' | sed -n 's/.*"Tags":\[\([^]]*\)\].*/\1/p' | tr -d '"' | sorted || true)"
      if [ "$CUR_TAGS" = "$(printf '%s' "$TAGS_RAW" | sorted)" ]; then
        ok "tags already ${TAGS_RAW}"
      elif api_post "/device/${NODE_ID}/tags" "{\"tags\": $(json_list "${TAGS[@]}")}"; then
        ok "tags set to ${TAGS_RAW}"
      else
        warn "setting the tags failed: ${API_ERR}$([[ "$API_ERR" == "HTTP 40"[13]* ]] && echo " (the OAuth client needs the devices:core scope and must own ${TAGS_RAW})")"
      fi
    fi
    # Approved routes = exactly what this node advertises (the call replaces the whole list)
    APPROVE=("${ROUTES[@]}")
    [ "$EXIT_NODE" = 1 ] && APPROVE+=("0.0.0.0/0" "::/0")
    if [ "${#APPROVE[@]}" -gt 0 ]; then
      if api_post "/device/${NODE_ID}/routes" "{\"routes\": $(json_list "${APPROVE[@]}")}"; then
        ROUTES_RESULT="approved: ${#ROUTES[@]} subnet route(s)$([ "$EXIT_NODE" = 1 ] && echo " + exit node")"
        ok "routes ${ROUTES_RESULT}"
      else
        warn "route approval failed: ${API_ERR}$([[ "$API_ERR" == "HTTP 40"[13]* ]] && echo " (the OAuth client lacks the devices:routes scope)")"
        ROUTES_RESULT="approval failed"
      fi
    fi
    if [ -n "$WANT_IP" ]; then
      if [ "$(ts_ip4)" = "$WANT_IP" ]; then
        ok "tailnet IP already as requested"
      else
        IP_RESULT="change requested"
      fi
    fi
  fi
elif [ -n "$OAUTH_SECRET" ]; then
  warn "node is not logged in (backend ${BACKEND:-unknown}); skipping the API steps"
fi

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] backend: ${BACKEND:-unknown}"
[ "$BACKEND" = "NeedsLogin" ] && echo "[*] log in: sudo docker exec -it ${CONTAINER_NAME} tailscale up   (open the printed URL)"
echo "[*] exit node: $([ "$EXIT_NODE" = 1 ] && echo advertised || echo off)"
echo "[*] subnet routes: ${#ROUTES[@]} advertised"
echo "[*] route approval: ${ROUTES_RESULT}"
echo "[*] filesystem: read-only (writable: /tmp tmpfs, node state, socket dir)"
echo "[*] memory: ${MEM:-unknown}"

# OPI_TS_IP held by another machine? A re-login (machine removed, key revoked) makes a new node,
# and the old entry can keep the IP. Only an offline entry with this node's hostname, i.e. this
# Pi's own leftover, is removed; anything else is left alone and named.
free_ip() {
  local devices holder hid hname
  devices="$(curl -fsS -m 30 -H @"$API_HDR" "${API}/tailnet/-/devices" 2>/dev/null)" \
    || { warn "could not list the tailnet's machines; trying the IP change anyway"; return 0; }
  # The default device fields hold no nested objects, so "},{" separates devices
  holder="$(printf '%s' "$devices" | tr -d '\n' | sed 's/},{/}\n{/g' | grep -F "\"${WANT_IP}\"" | head -n1 || true)"
  [ -n "$holder" ] || return 0
  hid="$(printf '%s' "$holder" | sed -n 's/.*"nodeId" *: *"\([^"]*\)".*/\1/p')"
  hname="$(printf '%s' "$holder" | sed -n 's/.*"hostname" *: *"\([^"]*\)".*/\1/p')"
  [ "$hid" = "$NODE_ID" ] && return 0
  if [ "$hname" = "$TS_HOST" ] && printf '%s' "$holder" | grep -q '"connectedToControl" *: *false'; then
    step "removing this Pi's offline leftover machine entry that still holds OPI_TS_IP"
    if curl -fsS -m 30 -o /dev/null -X DELETE -H @"$API_HDR" "${API}/device/${hid}" 2>/dev/null; then
      ok "old entry removed; the IP is free"
      return 0
    fi
    warn "could not remove the old entry (the OAuth client needs the devices:core scope)"
    return 1
  fi
  warn "OPI_TS_IP belongs to another machine (${hname:-unknown}$(printf '%s' "$holder" | grep -q '"connectedToControl" *: *true' && echo ", online")); not touching it"
  return 1
}

# Last on purpose: a new IP drops every connection to the old one, this SSH session included
if [ "$IP_RESULT" = "change requested" ]; then
  free_ip || fail "OPI_TS_IP is still taken; free it in the admin console (Machines) and rerun"
  step "moving the node to the requested tailnet IP; an SSH session on the old IP will drop now"
  api_post "/device/${NODE_ID}/ip" "{\"ipv4\": \"${WANT_IP}\"}" \
    || fail "setting the IP failed: ${API_ERR}$([[ "$API_ERR" == "HTTP 40"[13]* ]] && echo " (the OAuth client lacks the devices:core scope)" || echo " (is the IP free in the tailnet and inside 100.64.0.0/10?)")"
  for _ in $(seq 1 15); do
    [ "$(ts_ip4)" = "$WANT_IP" ] && { ok "tailnet IP changed"; break; }
    sleep 2
  done
  [ "$(ts_ip4)" = "$WANT_IP" ] || warn "the IP change was accepted but has not reached the node yet"
fi
ok "init tailscale-docker done"

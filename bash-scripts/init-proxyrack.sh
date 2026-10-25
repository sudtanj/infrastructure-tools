#!/bin/bash
# bash-scripts/init-proxyrack.sh
# Idempotent deploy/update of the ProxyRack Peer client (sudtanj/proxyrack: the official Go
# client on distroless, non-root, pinned, no self-update; see builder-tools/proxyrack/) behind a
# Tailscale exit node. Built for the Instabox machine (.github/workflows/instabox-proxyrack.yaml
# runs it over SSH), works on any x86-64 Docker host with a TUN device.
#
# Layout:
#   proxyrack-ts  sudtanj/tailscale on its own network, kernel mode (TUN). It owns the network
#                 namespace and routes everything through the exit node.
#   proxyrack     joins that namespace (--network container:proxyrack-ts), so its only way out
#                 is the exit node: ProxyRack sees the exit node's IP, not this machine's.
# Firewall inside that namespace, for the client's uid (65532) only, applied before it starts:
#   - anything not leaving through tailscale0 is rejected, so if the tunnel or the exit node
#     goes away the client is cut off instead of falling back to this machine's IP;
#   - private, Tailscale, link-local, multicast and reserved ranges are rejected, so proxy
#     customers can't reach the exit node's LAN, the tailnet or this machine's network;
#   - SMTP (25/465/587) and DNS-over-TLS (853) are rejected; plain DNS to any server is
#     redirected to AdGuard Family Protection; IPv6 is rejected.
#
# Security model (this repo is public and its Actions logs are public):
#   - The device ID, auth key, exit node, host names and IPs are never printed.
#   - The device ID is a command-line argument of the container (visible to root on the
#     machine). The auth key only sits in a RAM file (/run) until the node is up, then deleted.
#   - Tailscale state is in memory: the node is ephemeral, and is gone once the container
#     stops. Neither container comes back after a reboot (a fresh auth key is needed); the
#     next workflow run redeploys both.
#
# Env:
#   PROXYRACK_UUID          device ID (required): 32-64 letters/digits, kept stable so the
#                           dashboard keeps one device
#   PROXYRACK_TS_AUTHKEY    Tailscale auth key, ideally single-use + ephemeral + tagged
#                           (required when the containers have to be (re)created)
#   PROXYRACK_TS_EXIT_NODE  exit node: tag:name, a MagicDNS name or a Tailscale IPv4 (required)
#   PROXYRACK_IMAGE         default sudtanj/proxyrack:latest
#   PROXYRACK_TS_IMAGE      default sudtanj/tailscale:latest
#   PROXYRACK_TOOLS_IMAGE   default tailscale/tailscale:v1.104.1 (only its iptables and wget,
#                           in short-lived containers that apply the rules and test egress)
#   PROXYRACK_CPU_LIMIT     default 0.5    PROXYRACK_MEMORY_LIMIT     default 128m (no swap)
#   PROXYRACK_TS_CPU_LIMIT  default 0.5    PROXYRACK_TS_MEMORY_LIMIT  default 128m (no swap)

set -euo pipefail

CONTAINER_NAME="proxyrack"
TS_NAME="proxyrack-ts"
NETWORK_NAME="proxyrack-net"
NETWORK_SUBNET="10.213.53.56/29"  # after the Orange Pi clients (.0 to .48); a separate machine, same plan
RUN_DIR="/run/proxyrack"          # tmpfs: the tailscaled config with the auth key, and resolv.conf
CLIENT_UID=65532
PIDS_LIMIT=64
IMAGE="${PROXYRACK_IMAGE:-sudtanj/proxyrack:latest}"
TS_IMAGE="${PROXYRACK_TS_IMAGE:-sudtanj/tailscale:latest}"
TOOLS_IMAGE="${PROXYRACK_TOOLS_IMAGE:-tailscale/tailscale:v1.104.1}"
UUID="${PROXYRACK_UUID:-}"
AUTHKEY="${PROXYRACK_TS_AUTHKEY:-}"
EXIT_NODE="${PROXYRACK_TS_EXIT_NODE:-}"
CPU_LIMIT="${PROXYRACK_CPU_LIMIT:-0.5}"
MEMORY_LIMIT="${PROXYRACK_MEMORY_LIMIT:-128m}"
TS_CPU_LIMIT="${PROXYRACK_TS_CPU_LIMIT:-0.5}"
TS_MEMORY_LIMIT="${PROXYRACK_TS_MEMORY_LIMIT:-128m}"
DNS_SERVERS=(94.140.14.15 94.140.15.16)   # AdGuard Family Protection
BLOCKED_RANGES=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16
  224.0.0.0/4 240.0.0.0/4 0.0.0.0/8 192.0.0.0/24 198.18.0.0/15)
RULES_VERSION="v1"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
debug()  { [ "${INIT_DEBUG:-0}" = "1" ] && printf '%s\n' "[d] $*" || true; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=(); else SUDO=(sudo -n); fi
if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo -n docker)
fi

status "init proxyrack start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
[ "$(uname -m)" = "x86_64" ] || fail "unsupported arch $(uname -m); ProxyRack only ships an x86-64 client"
[[ "$UUID" =~ ^[A-Za-z0-9]{32,64}$ ]] || fail "PROXYRACK_UUID must be 32-64 letters/digits"
[[ "$EXIT_NODE" =~ ^tag:[A-Za-z0-9][A-Za-z0-9_-]*$ || "$EXIT_NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "PROXYRACK_TS_EXIT_NODE must be tag:name, a MagicDNS name or a Tailscale IPv4"
[ -z "$AUTHKEY" ] || [[ "$AUTHKEY" =~ ^tskey-[A-Za-z0-9_-]+$ ]] || fail "PROXYRACK_TS_AUTHKEY does not look like a Tailscale auth key"
command -v jq >/dev/null 2>&1 || fail "jq is required"
if [ ! -c /dev/net/tun ]; then
  "${SUDO[@]}" modprobe tun 2>/dev/null || true
  [ -c /dev/net/tun ] || fail "no TUN device (/dev/net/tun); kernel-mode Tailscale needs it"
fi
LOG_OPTS=(--log-driver json-file --log-opt max-size=1m --log-opt max-file=1)
ok "docker ready (x86_64, TUN present)"

# ---------------------------------------------------------------------------
# 2. Own network (no traffic between containers on it)
# ---------------------------------------------------------------------------
step "preparing network ${NETWORK_NAME}"
if ! "${DOCKER[@]}" network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  "${DOCKER[@]}" network create --driver bridge --subnet "$NETWORK_SUBNET" \
    -o com.docker.network.bridge.name=br-proxyrack \
    -o com.docker.network.bridge.enable_icc=false "$NETWORK_NAME" >/dev/null \
    || fail "failed to create ${NETWORK_NAME} (subnet ${NETWORK_SUBNET} may clash with another network)"
fi
HAVE_SUBNET="$("${DOCKER[@]}" network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK_NAME")"
[ "$HAVE_SUBNET" = "$NETWORK_SUBNET" ] || fail "${NETWORK_NAME} exists with another subnet; remove it and re-run"
ok "network ready"

# ---------------------------------------------------------------------------
# 3. Images
# ---------------------------------------------------------------------------
pull() {
  local attempt
  for attempt in 1 2 3; do
    "${DOCKER[@]}" pull "$1" >/dev/null 2>&1 && return 0
    warn "pull of $1 failed (attempt ${attempt}/3)"
    [ "$attempt" -lt 3 ] && sleep $(( attempt * 5 ))
  done
  fail "failed to pull $1"
}
step "pulling images"
pull "$IMAGE"; pull "$TS_IMAGE"; pull "$TOOLS_IMAGE"
IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE")"
TS_IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$TS_IMAGE")"
TOOLS_IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$TOOLS_IMAGE")"
ok "images ready"

# Status of the node, reduced to fields that identify nothing.
ts_json() { "${DOCKER[@]}" exec "$TS_NAME" tailscale status --json 2>/dev/null; }
ts_healthy() {
  local j
  j="$(ts_json)" || return 1
  [ "$(jq -r '.BackendState // ""' <<< "$j")" = "Running" ] \
    && [ "$(jq -r '.ExitNodeStatus.Online // false' <<< "$j")" = "true" ]
}
# A short-lived container in the shared namespace, as the client's uid and with its
# resolv.conf, so it takes exactly the client's path out.
probe_egress() {
  "${DOCKER[@]}" run --rm --network "container:${TS_NAME}" --user "${CLIENT_UID}:${CLIENT_UID}" \
    -v "${RUN_DIR}/resolv.conf:/etc/resolv.conf:ro" --cap-drop ALL --security-opt no-new-privileges \
    --read-only --memory 32m --pids-limit 16 --log-driver none --entrypoint wget "$TOOLS_IMAGE" \
    -qO- -T 15 http://api.ipify.org 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 4. Skip the restart when nothing changed and the tunnel is healthy
# ---------------------------------------------------------------------------
# Hash of every setting (device ID included, never printed; the single-use auth key is not part
# of it). An unchanged run leaves a healthy pair alone.
WANT_SUM="$(printf '%s\n' "$IMAGE_ID" "$TS_IMAGE_ID" "$TOOLS_IMAGE_ID" "$UUID" "$EXIT_NODE" "$CPU_LIMIT" "$MEMORY_LIMIT" \
  "$TS_CPU_LIMIT" "$TS_MEMORY_LIMIT" "$PIDS_LIMIT" "${DNS_SERVERS[*]}" "${BLOCKED_RANGES[*]}" "$NETWORK_NAME" "$RULES_VERSION" \
  | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "proxyrack.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
TS_STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$TS_NAME" 2>/dev/null || echo missing)"

if [ "$WANT_SUM" = "$HAVE_SUM" ] && [ "$STATE" = running ] && [ "$TS_STATE" = running ] && ts_healthy; then
  ok "${CONTAINER_NAME} already running with the current images and settings, exit node online"
else
  debug "recreate reason: client=${STATE}, tailscale=${TS_STATE}, config $([ "$WANT_SUM" = "$HAVE_SUM" ] && echo same || echo changed)"
  [ -n "$AUTHKEY" ] || fail "PROXYRACK_TS_AUTHKEY is needed to (re)create the containers"

  # -------------------------------------------------------------------------
  # 5. Replace both containers (the client's namespace belongs to the tailscale one)
  # -------------------------------------------------------------------------
  step "removing existing containers"
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" "$TS_NAME" >/dev/null 2>&1 || true
  ok "old containers gone"

  # RAM only. resolv.conf is mounted into both containers: on a user-defined network Docker
  # would point them at its own resolver on 127.0.0.11, which can't be redirected to AdGuard.
  "${SUDO[@]}" install -d -m 0755 "$RUN_DIR"
  printf 'nameserver %s\n' "${DNS_SERVERS[@]}" | "${SUDO[@]}" tee "${RUN_DIR}/resolv.conf" >/dev/null
  "${SUDO[@]}" chmod 0644 "${RUN_DIR}/resolv.conf"
  # Fresh random node name per deploy.
  NODE_NAME="proxyrack-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
  [[ "$NODE_NAME" =~ ^proxyrack-[0-9a-f]{6}$ ]] || fail "could not generate a node name"
  ( umask 077
    jq -n --arg k "$AUTHKEY" --arg h "$NODE_NAME" \
      '{Version: "alpha0", Locked: false, AuthKey: $k, Hostname: $h,
        AcceptDNS: false, AcceptRoutes: false}' \
      | "${SUDO[@]}" tee "${RUN_DIR}/tailscaled.json" >/dev/null )
  "${SUDO[@]}" chmod 0600 "${RUN_DIR}/tailscaled.json"
  "${SUDO[@]}" chown 0:0 "${RUN_DIR}/tailscaled.json"
  trap '"${SUDO[@]}" rm -f "${RUN_DIR}/tailscaled.json"' EXIT

  step "starting ${TS_NAME}"
  # --restart no: state is in memory and the auth key is single-use, so a restarted node
  # could not log in again; the next workflow run recreates it.
  "${DOCKER[@]}" run -d --name "$TS_NAME" \
    --restart no \
    --hostname "$NODE_NAME" \
    --network "$NETWORK_NAME" \
    --label "proxyrack.config=${WANT_SUM}" \
    --device /dev/net/tun:/dev/net/tun \
    --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW --security-opt no-new-privileges \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
    --tmpfs /var/run:rw,noexec,nosuid,nodev,size=1m \
    --tmpfs /var/lib/tailscale:rw,noexec,nosuid,nodev,size=8m \
    -v "${RUN_DIR}/tailscaled.json:/etc/tailscale/tailscaled.json:ro" \
    -v "${RUN_DIR}/resolv.conf:/etc/resolv.conf:ro" \
    --cpus "$TS_CPU_LIMIT" --memory "$TS_MEMORY_LIMIT" --memory-swap "$TS_MEMORY_LIMIT" \
    --pids-limit "$PIDS_LIMIT" -e GOMEMLIMIT=96MiB \
    "${LOG_OPTS[@]}" \
    "$TS_IMAGE" --config=/etc/tailscale/tailscaled.json --state=mem: >/dev/null \
    || fail "failed to start ${TS_NAME}"

  # -------------------------------------------------------------------------
  # 6. Firewall in the shared namespace, before the client exists
  # -------------------------------------------------------------------------
  step "applying the client firewall"
  RULES="set -e
IPT=iptables; IP6T=ip6tables
if command -v iptables-nft >/dev/null 2>&1 && iptables-nft -S >/dev/null 2>&1; then IPT=iptables-nft; IP6T=ip6tables-nft; fi
U=${CLIENT_UID}
\$IPT -N PR-EGRESS 2>/dev/null || \$IPT -F PR-EGRESS
\$IPT -A PR-EGRESS -o lo -j RETURN
\$IPT -A PR-EGRESS ! -o tailscale0 -j REJECT
for r in ${BLOCKED_RANGES[*]}; do \$IPT -A PR-EGRESS -d \"\$r\" -j REJECT; done
\$IPT -A PR-EGRESS -p tcp -m multiport --dports 25,465,587,853 -j REJECT
\$IPT -A PR-EGRESS -p udp --dport 853 -j REJECT
\$IPT -C OUTPUT -m owner --uid-owner \$U -j PR-EGRESS 2>/dev/null || \$IPT -I OUTPUT 1 -m owner --uid-owner \$U -j PR-EGRESS
\$IPT -t nat -N PR-DNS 2>/dev/null || \$IPT -t nat -F PR-DNS
for d in ${DNS_SERVERS[*]}; do \$IPT -t nat -A PR-DNS -d \"\$d\" -j RETURN; done
\$IPT -t nat -A PR-DNS -p udp --dport 53 -j DNAT --to-destination ${DNS_SERVERS[0]}:53
\$IPT -t nat -A PR-DNS -p tcp --dport 53 -j DNAT --to-destination ${DNS_SERVERS[0]}:53
\$IPT -t nat -C OUTPUT -m owner --uid-owner \$U ! -d 127.0.0.0/8 -j PR-DNS 2>/dev/null || \$IPT -t nat -I OUTPUT 1 -m owner --uid-owner \$U ! -d 127.0.0.0/8 -j PR-DNS
\$IP6T -C OUTPUT -m owner --uid-owner \$U -j REJECT 2>/dev/null || \$IP6T -I OUTPUT 1 -m owner --uid-owner \$U -j REJECT
\$IPT -C OUTPUT -m owner --uid-owner \$U -j PR-EGRESS
\$IPT -C PR-EGRESS ! -o tailscale0 -j REJECT
\$IPT -C PR-EGRESS -d 192.168.0.0/16 -j REJECT
\$IP6T -C OUTPUT -m owner --uid-owner \$U -j REJECT"
  "${DOCKER[@]}" run --rm --network "container:${TS_NAME}" --user 0:0 \
    --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW --security-opt no-new-privileges \
    --read-only --tmpfs /run:rw,noexec,nosuid,nodev,size=1m --memory 64m --pids-limit 16 --log-driver none \
    --entrypoint sh "$TOOLS_IMAGE" -c "$RULES" >/dev/null 2>&1 \
    || { "${DOCKER[@]}" rm -f "$TS_NAME" >/dev/null 2>&1 || true; fail "could not apply the firewall (iptables owner match missing?); nothing started"; }
  ok "client firewall in place (tunnel only, LAN and tailnet blocked, DNS to AdGuard, no IPv6)"

  # -------------------------------------------------------------------------
  # 7. Join the tailnet, then pick the exit node
  # -------------------------------------------------------------------------
  step "waiting for ${TS_NAME} to join the tailnet"
  JOINED=0
  for _ in $(seq 1 45); do
    [ "$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$TS_NAME" 2>/dev/null)" = running ] || break
    if [ "$(ts_json | jq -r '.BackendState // ""')" = "Running" ]; then JOINED=1; break; fi
    sleep 2
  done
  [ "$JOINED" = 1 ] || { "${DOCKER[@]}" logs --tail 10 "$TS_NAME" 2>&1 | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g; s/tskey-[A-Za-z0-9_-]+/<key>/g; s/proxyrack-[0-9a-f]{6}/<node>/g' | sed 's/^/[!]   /' >&2
    fail "tailscale did not reach Running (auth key expired or used, or the tag is not allowed)"; }
  "${SUDO[@]}" rm -f "${RUN_DIR}/tailscaled.json"
  ok "joined the tailnet (auth key file removed)"

  # tag:name is resolved here to the address of an online peer with that tag that offers an exit
  # node; names and addresses are passed as they are.
  TARGET="$EXIT_NODE"
  if [ "${EXIT_NODE#tag:}" != "$EXIT_NODE" ]; then
    TARGET="$(ts_json | jq -r --arg t "$EXIT_NODE" \
      '[.Peer[]? | select(.Online == true and .ExitNodeOption == true and (((.Tags // []) | index($t)) != null))
       | .TailscaleIPs[]? | select(test("^[0-9.]+$"))] | first // ""')"
    [ -n "$TARGET" ] || fail "no online exit node with the configured tag"
  fi
  # --shields-up: no connections in from the tailnet.
  "${DOCKER[@]}" exec "$TS_NAME" tailscale set --exit-node="$TARGET" --exit-node-allow-lan-access=false --shields-up >/dev/null 2>&1 \
    || fail "tailscale refused the exit node (offline, not an exit node, or not allowed by the ACL)"
  for _ in $(seq 1 15); do ts_healthy && break; sleep 2; done
  ts_healthy || fail "the exit node is not online"
  ok "exit node in use"

  # -------------------------------------------------------------------------
  # 8. Client
  # -------------------------------------------------------------------------
  step "starting ${CONTAINER_NAME}"
  # -i: the client exits when its stdin closes.
  "${DOCKER[@]}" run -d -i --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --network "container:${TS_NAME}" \
    --user "${CLIENT_UID}:${CLIENT_UID}" \
    --label "proxyrack.config=${WANT_SUM}" \
    -v "${RUN_DIR}/resolv.conf:/etc/resolv.conf:ro" \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=8m,uid=${CLIENT_UID},gid=${CLIENT_UID} \
    --tmpfs /home/nonroot:rw,noexec,nosuid,nodev,size=8m,uid=${CLIENT_UID},gid=${CLIENT_UID},mode=0700 \
    --cpus "$CPU_LIMIT" --cpu-shares 256 \
    --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" \
    --oom-score-adj 500 \
    --pids-limit "$PIDS_LIMIT" \
    --cap-drop ALL --security-opt no-new-privileges \
    -e GOMAXPROCS=1 -e GOMEMLIMIT=96MiB \
    "${LOG_OPTS[@]}" \
    "$IMAGE" --id "$UUID" >/dev/null \
    || fail "failed to start ${CONTAINER_NAME}"
fi

# ---------------------------------------------------------------------------
# 9. Verify: egress through the exit node, client stays up
# ---------------------------------------------------------------------------
step "verifying egress"
DIRECT_IP="$(curl -fsS -m 10 http://api.ipify.org 2>/dev/null || true)"
TUNNEL_IP="$(probe_egress)"
[[ "$TUNNEL_IP" =~ ^[0-9.]+$ ]] || fail "the client's path out does not work (exit node or DNS down)"
[ "$TUNNEL_IP" != "$DIRECT_IP" ] || fail "the client's traffic leaves from this machine's IP, not the exit node"
unset DIRECT_IP TUNNEL_IP
ok "client traffic leaves through the exit node (IPs not printed)"

show_logs() {
  local line
  "${DOCKER[@]}" logs --tail "$1" "$CONTAINER_NAME" 2>&1 \
    | grep -av '^[[:space:]]*$' \
    | sed -E 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/<email>/g; s/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/<id>/g; s/[0-9A-Fa-f]{24,}/<id>/g; s/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g; s/[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4})*::[0-9A-Fa-f:]*|([0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}/<ipv6>/g' \
    | while IFS= read -r line; do printf '%s %s\n' "$2" "${line//"$UUID"/<id>}"; done || true
}

step "checking ${CONTAINER_NAME} stays up"
RESTARTS_BEFORE="$("${DOCKER[@]}" inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
sleep 20
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
RESTARTS="$("${DOCKER[@]}" inspect -f '{{.RestartCount}}' "$CONTAINER_NAME" 2>/dev/null || echo 0)"
OOM="$("${DOCKER[@]}" inspect -f '{{.State.OOMKilled}}' "$CONTAINER_NAME" 2>/dev/null || echo false)"
if [ "$STATE" != "running" ] || [ "${RESTARTS:-0}" -gt "${RESTARTS_BEFORE:-0}" ]; then
  warn "state: ${STATE}, restarts during check: $(( ${RESTARTS:-0} - ${RESTARTS_BEFORE:-0} ))"
  show_logs 15 '[!]  ' >&2
  [ "$OOM" = "true" ] && fail "${CONTAINER_NAME} hit the ${MEMORY_LIMIT} memory cap; raise PROXYRACK_MEMORY_LIMIT"
  fail "${CONTAINER_NAME} is not staying up (see the log above)"
fi
[ "${INIT_DEBUG:-0}" = "1" ] && show_logs 10 '[d]  '
unset UUID AUTHKEY
ok "${CONTAINER_NAME} is up"

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.Name}} {{.MemUsage}} cpu {{.CPUPerc}}' "$CONTAINER_NAME" "$TS_NAME" 2>/dev/null | paste -sd';' - || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE} (tunnel: ${TS_IMAGE})"
echo "[*] limits: client cpu ${CPU_LIMIT} / ${MEMORY_LIMIT}, tailscale cpu ${TS_CPU_LIMIT} / ${TS_MEMORY_LIMIT} (no swap)"
echo "[*] egress: exit node only (fails closed); lan/tailnet blocked; dns AdGuard Family; no IPv6"
echo "[*] usage: ${MEM:-unknown}"
ok "init proxyrack done"

#!/usr/bin/env bash
# Runs the ProxyRack client for a set time inside an ephemeral GitHub runner job
# (no Docker, no TUN device, no NET_ADMIN), with all of its traffic leaving
# through a Tailscale exit node:
#
#   proxyrack --(graftcp traces its syscalls)--> proxyrack-guard (127.0.0.1:1081)
#     --> tailscaled SOCKS5 (127.0.0.1:1055, userspace) --> exit node --> internet
#
#   - TCP: graftcp sends every connection, loopback included, to the guard. The
#     guard passes only public IPv4 on: no private ranges (so not the exit node's
#     LAN or this machine's network), no tailnet, no IPv6, no mail ports.
#   - DNS: graftcp turns UDP/53 into DNS-over-TCP through the same path; the
#     guard sends every port-53 connection to AdGuard Family.
#   - Other UDP: graftcp's only_socks5 mode never sends it directly, and the
#     guard refuses UDP ASSOCIATE, so it is dropped.
#   - Fails closed: if graftcp exits, the kernel kills the client with it
#     (PTRACE_O_EXITKILL); if the guard, tailscaled or the exit node is down,
#     connections fail instead of going direct. The exit node is set before the
#     guard starts, and the client stops if it is ever unset.
#
# Nothing is written outside RUN_DIR. The device ID, auth key, exit node and
# IPs are never printed; the client's own output is cut to its first lines.
#
# Environment:
#   PROXYRACK_UUID       device ID, 32-64 letters/digits (required)
#   TS_AUTHKEY           Tailscale auth key (required)
#   TS_TAGS              tags to advertise (needed with an OAuth-minted key)
#   TS_EXIT_NODE         tag:name, a MagicDNS name or a Tailscale IPv4 (required)
#   RUN_SECONDS          how long to run (default 3600)
#   RUN_DIR              scratch dir for sockets and logs (default: a mktemp dir)
set -euo pipefail

B="$(cd "$(dirname "$0")" && pwd)"
RUN_SECONDS="${RUN_SECONDS:-3600}"
DNS_SERVER="94.140.14.15:53"
SOCKS_TS="127.0.0.1:1055"
SOCKS_GUARD="127.0.0.1:1081"
CLIENT_LOG_LINES=40

step() { printf '%s\n' "[>] $*"; }
ok()   { printf '%s\n' "[+] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
fail() { printf '%s\n' "[x] $*" >&2; exit 1; }

[[ "${PROXYRACK_UUID:-}" =~ ^[A-Za-z0-9]{32,64}$ ]] || fail "PROXYRACK_UUID must be 32-64 letters/digits"
[ -n "${TS_AUTHKEY:-}" ] || fail "TS_AUTHKEY is required"
EXIT_NODE="${TS_EXIT_NODE:-}"
[[ "$EXIT_NODE" =~ ^tag:[A-Za-z0-9][A-Za-z0-9_-]*$ || "$EXIT_NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "TS_EXIT_NODE must be tag:name, a MagicDNS name or a Tailscale IPv4"
[[ "$RUN_SECONDS" =~ ^[0-9]+$ ]] || fail "RUN_SECONDS must be a number"
[ "$(uname -m)" = x86_64 ] || fail "x86_64 only (ProxyRack builds the client for x86-64 only)"
for t in curl jq; do command -v "$t" >/dev/null || fail "$t is required"; done

RUN_DIR="${RUN_DIR:-$(mktemp -d)}"
mkdir -p "$RUN_DIR"
cd "$RUN_DIR"
SOCK="$RUN_DIR/tailscaled.sock"
ts() { "$B/tailscale" --socket="$SOCK" "$@"; }
DEADLINE=$(( $(date +%s) + RUN_SECONDS ))

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  ts logout >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 1. Tailscale in userspace mode, state in memory only.
step "starting tailscaled (userspace)"
"$B/tailscaled" --tun=userspace-networking --state=mem: \
  --socket="$SOCK" --socks5-server="$SOCKS_TS" > "$RUN_DIR/tailscaled.log" 2>&1 &
PIDS+=("$!")
tag_args=()
[ -z "${TS_TAGS:-}" ] || tag_args=(--advertise-tags="$TS_TAGS")
joined=0
for attempt in 1 2 3; do
  if ts up --authkey="$TS_AUTHKEY" "${tag_args[@]}" --hostname="proxyrack-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')" \
       --accept-dns=false --accept-routes=false --shields-up --timeout=90s >/dev/null 2>&1; then
    joined=1; break
  fi
  sleep 5
done
unset TS_AUTHKEY
[ "$joined" = 1 ] || fail "could not join the tailnet (key rejected or expired?)"
ok "joined the tailnet"

# 2. Exit node. tag:name resolves to an online peer with that tag that offers one.
TARGET="$EXIT_NODE"
if [ "${EXIT_NODE#tag:}" != "$EXIT_NODE" ]; then
  TARGET="$(ts status --json | jq -r --arg t "$EXIT_NODE" \
    '[.Peer[]? | select(.Online == true and .ExitNodeOption == true and (((.Tags // []) | index($t)) != null))
     | .TailscaleIPs[]? | select(test("^[0-9.]+$"))] | first // ""')"
  [ -n "$TARGET" ] || fail "no online exit node with the configured tag"
fi
ts set --exit-node="$TARGET" --exit-node-allow-lan-access=false >/dev/null 2>&1 \
  || fail "tailscale refused the exit node (offline, not an exit node, or not allowed by the ACL)"
exit_node_ok() { ts status --json 2>/dev/null | jq -e '.ExitNodeStatus.Online == true' >/dev/null; }
for _ in $(seq 1 30); do exit_node_ok && break; sleep 2; done
exit_node_ok || fail "the exit node is not online"
ok "exit node in use"

# 3. The guard, then a test through the client's exact path.
"$B/proxyrack-guard" -listen "$SOCKS_GUARD" -upstream "$SOCKS_TS" -dns "$DNS_SERVER" \
  > "$RUN_DIR/guard.log" 2>&1 &
PIDS+=("$!")
sleep 1
kill -0 "${PIDS[-1]}" 2>/dev/null || fail "proxyrack-guard did not start"

GRAFT=("$B/graftcp" --not-ignore-local --select_proxy_mode only_socks5 --socks5 "$SOCKS_GUARD"
       --enable-dns --dns-server "$DNS_SERVER" --enable-udp)
direct_ip="$(curl -fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
tunnel_ip="$("${GRAFT[@]}" -- curl -fsS --max-time 30 https://api.ipify.org 2>/dev/null || true)"
for ip in "$direct_ip" "$tunnel_ip"; do [ -z "$ip" ] || echo "::add-mask::$ip"; done
[[ "$tunnel_ip" =~ ^[0-9.]+$ ]] || fail "nothing gets out through graftcp -> guard -> exit node (ptrace blocked, or DNS/exit node down)"
[ "$tunnel_ip" != "$direct_ip" ] || fail "traffic leaves from this machine's IP, not the exit node"
# Loopback must hit the guard too: going straight to tailscaled's SOCKS5 port would skip it.
if "${GRAFT[@]}" -- curl -fsS --max-time 15 --socks5 "$SOCKS_TS" -o /dev/null https://api.ipify.org 2>/dev/null; then
  fail "a loopback connection got past the guard"
fi
ok "client path leaves through the exit node; loopback refused (IPs not printed)"

# 4. The client, until the deadline. Its stdin is a sleep that ends at the deadline:
# the client exits when its stdin closes. It is restarted if it stops early.
mask_log() {
  awk -v max="$CLIENT_LOG_LINES" '
    { gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "<ip>") }
    NR <= max { print "    " $0; fflush() }
    NR == max + 1 { print "    (further client output hidden)"; fflush() }'
}
ARGS=(--homeIp point-of-presence.sock.sh --homePort 443 --clientKey proxyrack-pop-client
      --clientType PoP --version 60 --osType Linux --osArch x64 --id "$PROXYRACK_UUID")
quick_exits=0
while :; do
  remaining=$(( DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 60 ] || break
  started=$(date +%s)
  # A clean environment: nothing from the job reaches the client. The Go limits are set
  # inside graftcp, for the client only: graftcp is Go too, and with GOMAXPROCS=1 it lost
  # track of the client (see the Dockerfile).
  env -i PATH=/usr/bin:/bin HOME="$RUN_DIR" \
    "${GRAFT[@]}" -- /usr/bin/env GOMAXPROCS=1 GOMEMLIMIT=96MiB "$B/proxyrack" "${ARGS[@]}" \
    < <(exec sleep "$remaining") > >(mask_log) 2>&1 &
  CPID=$!
  PIDS+=("$CPID")
  ok "client started for $(( remaining / 60 )) min"
  n=0
  while kill -0 "$CPID" 2>/dev/null; do
    sleep 60
    n=$((n + 1))
    # Never let the client run without the exit node set.
    if ! ts status --json 2>/dev/null | jq -e '.ExitNodeStatus != null' >/dev/null; then
      kill "$CPID" 2>/dev/null || true
      fail "the exit node is no longer set; client stopped"
    fi
    if [ $((n % 60)) -eq 0 ]; then
      if exit_node_ok; then s="online"; else s="OFFLINE (client traffic blocked)"; fi
      printf '[*] %s client up, exit node %s, %s min left\n' "$(date -u +%H:%M)" "$s" $(( (DEADLINE - $(date +%s)) / 60 ))
    fi
  done
  wait "$CPID" 2>/dev/null || true
  [ $(( DEADLINE - $(date +%s) )) -gt 60 ] || break
  if [ $(( $(date +%s) - started )) -lt 300 ]; then quick_exits=$((quick_exits + 1)); else quick_exits=0; fi
  [ "$quick_exits" -lt 5 ] || fail "the client keeps exiting within 5 minutes"
  warn "client exited early; restarting in 30 s"
  sleep 30
done
ok "run finished"

#!/usr/bin/env bash
# Runs the Wipter app for a set time inside an ephemeral GitHub runner job (no
# Docker, no TUN device, no NET_ADMIN, no X server), with all of its traffic
# leaving through a Tailscale exit node. The same design as proxyrack-bundle's
# run.sh (see there), with Wipter's differences marked:
#
#   wipter app (+ its Chromium helpers and wipter-tunnel) --(graftcp)-->
#     wipter-guard (127.0.0.1:1083) --> tailscaled SOCKS5 (127.0.0.1:1057,
#     userspace) --> exit node --> internet
#
#   - TCP: graftcp sends every connection of the app and all its child
#     processes, loopback included, to the guard. The guard passes only public
#     IPv4 on, plus (Wipter) 127.0.0.1:2000 dialed directly: the app's own
#     SOCKS5 server, which its wipter-tunnel process connects to. run.sh makes
#     sure the port is free first, so the app takes that one.
#   - DNS: DNS-over-TCP through the same path, always to AdGuard Family.
#   - Other UDP is dropped, never sent directly.
#   - Fails closed, as in proxyrack-bundle.
#   - Ports differ from proxyrack-bundle's (the jobs share the host network),
#     and tailscaled picks a free UDP port.
#
# The app runs from rt/, linked to /tmp/wipter-rt (the path its loader and
# libraries were relocated to), on the bundle's own Xvfb (no window manager). The
# shim inside it signs in, accepts the consent prompt and keeps sharing on. Its
# status lines are shown; the app's own output, the login, auth key, exit node
# and IPs are not.
#
# Environment:
#   WIPTER_EMAIL, WIPTER_PASSWORD   the Wipter account (required)
#   WIPTER_MACHINE_ID    32 hex digits; the app's device fingerprint when the
#                        host has no machine-id file (it then asks `hostname`)
#   TS_AUTHKEY           Tailscale auth key (required)
#   TS_TAGS              tags to advertise (needed with an OAuth-minted key)
#   TS_EXIT_NODE         tag:name, a MagicDNS name or a Tailscale IPv4 (required)
#   RUN_SECONDS          how long to run (default 3600)
#   RUN_DIR              scratch dir: sockets, logs, the app's profile (default: a mktemp dir)
#   VNC_VIEWER           optional: <tailnet device>[:port] (default port 5500)
#                        running a VNC viewer in listen mode; x11vnc connects
#                        out to it with the app's screen. Needs:
#   VNC_LISTEN=1         optional instead: x11vnc listens on port 5900 of this
#                        node (tailnet name wipter-instabox) for a viewer to
#                        connect in. Either one needs:
#   WIPTER_VNC_PASSWORD  the password the viewer must give
#
# The node is always named wipter-instabox, so its MagicDNS name stays the same
# from run to run (its IP doesn't: each run is a new ephemeral node).
#
# VNC_VIEWER is a reverse (outgoing) connection: nothing listens for the tailnet,
# so --shields-up stays on. x11vnc reaches the viewer through tailscaled's SOCKS5
# port under graftcp, so only tailnet addresses, not the exit node's internet.
# VNC_LISTEN drops --shields-up, and userspace tailscaled then forwards every
# inbound tailnet connection to 127.0.0.1 on the same port, which includes the
# app's SOCKS5 server and tailscaled's own: only the tailnet ACL stands in the
# way, so it should let peers reach this node's tag on port 5900 alone.
set -euo pipefail

B="$(cd "$(dirname "$0")" && pwd)"
RUN_SECONDS="${RUN_SECONDS:-3600}"
DNS_SERVER="94.140.14.15:53"
SOCKS_TS="127.0.0.1:1057"
SOCKS_GUARD="127.0.0.1:1083"
APP_SOCKS_PORT=2000
RT=/tmp/wipter-rt

step() { printf '%s\n' "[>] $*"; }
ok()   { printf '%s\n' "[+] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
fail() { printf '%s\n' "[x] $*" >&2; exit 1; }

[ -n "${WIPTER_EMAIL:-}" ] && [ -n "${WIPTER_PASSWORD:-}" ] || fail "WIPTER_EMAIL and WIPTER_PASSWORD are required"
[ -z "${WIPTER_MACHINE_ID:-}" ] || [[ "$WIPTER_MACHINE_ID" =~ ^[0-9a-f]{32}$ ]] || fail "WIPTER_MACHINE_ID must be 32 hex digits"
[ -n "${TS_AUTHKEY:-}" ] || fail "TS_AUTHKEY is required"
EXIT_NODE="${TS_EXIT_NODE:-}"
[[ "$EXIT_NODE" =~ ^tag:[A-Za-z0-9][A-Za-z0-9_-]*$ || "$EXIT_NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "TS_EXIT_NODE must be tag:name, a MagicDNS name or a Tailscale IPv4"
[[ "$RUN_SECONDS" =~ ^[0-9]+$ ]] || fail "RUN_SECONDS must be a number"
[ "$(uname -m)" = x86_64 ] || fail "x86_64 only"
VNC_VIEWER="${VNC_VIEWER:-}"
if [ -n "$VNC_VIEWER" ]; then
  [[ "$VNC_VIEWER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]{1,5})?$ ]] || fail "VNC_VIEWER must be <tailnet device>[:port]"
  [ -n "${WIPTER_VNC_PASSWORD:-}" ] || fail "VNC_VIEWER is set but WIPTER_VNC_PASSWORD is not"
fi
VNC_LISTEN="${VNC_LISTEN:-}"
[ "$VNC_LISTEN" != 1 ] || [ -n "${WIPTER_VNC_PASSWORD:-}" ] || fail "VNC_LISTEN is set but WIPTER_VNC_PASSWORD is not"
for t in curl jq timeout; do command -v "$t" >/dev/null || fail "$t is required"; done

# Wipter: the relocated app must sit at /tmp/wipter-rt, and Xvfb finds xkbcomp in /tmp/wxb.
link() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    [ "$(readlink "$2" 2>/dev/null)" = "$1" ] || fail "$2 exists and is not this bundle's"
  else
    ln -s "$1" "$2"
  fi
}
link "$B/rt" "$RT"
link "$RT/bin" /tmp/wxb
[ -x "$RT/app/wipter-app.bin" ] && [ -x "$RT/wipter-entry" ] || fail "the bundle is incomplete"
# Wipter: the app's SOCKS5 server must get the one port the guard lets through.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in "$APP_SOCKS_PORT" "${SOCKS_TS##*:}" "${SOCKS_GUARD##*:}"; do
  ! port_busy "$p" || fail "port $p on 127.0.0.1 is already in use (another job on this machine?)"
done

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
"$B/tailscaled" --tun=userspace-networking --state=mem: --port=0 \
  --socket="$SOCK" --socks5-server="$SOCKS_TS" > "$RUN_DIR/tailscaled.log" 2>&1 &
PIDS+=("$!")
tag_args=()
[ -z "${TS_TAGS:-}" ] || tag_args=(--advertise-tags="$TS_TAGS")
shields=--shields-up
[ "$VNC_LISTEN" != 1 ] || shields=--shields-up=false
joined=0
for attempt in 1 2 3; do
  if ts up --authkey="$TS_AUTHKEY" "${tag_args[@]}" --hostname=wipter-instabox \
       --accept-dns=false --accept-routes=false "$shields" --timeout=90s >/dev/null 2>&1; then
    joined=1; break
  fi
  sleep 5
done
unset TS_AUTHKEY
[ "$joined" = 1 ] || fail "could not join the tailnet (key rejected or expired?)"
ok "joined the tailnet as $(ts status --json 2>/dev/null | jq -r '.Self.HostName // "?"')"

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

# 3. The guard, then a test through the app's exact path.
"$B/wipter-guard" -listen "$SOCKS_GUARD" -upstream "$SOCKS_TS" -dns "$DNS_SERVER" \
  -local "127.0.0.1:$APP_SOCKS_PORT" > "$RUN_DIR/guard.log" 2>&1 &
PIDS+=("$!")
sleep 1
kill -0 "${PIDS[-1]}" 2>/dev/null || fail "wipter-guard did not start"

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
ok "app path leaves through the exit node; loopback refused (IPs not printed)"

# 4. The app, until the deadline (timeout runs inside graftcp and stops it with
# SIGTERM, which the launcher passes on). Restarted if it stops early, except
# after repeated sign-in failures (the shim then waits 30 minutes and exits).
mkdir -p "$RUN_DIR/home" "$RUN_DIR/tmp" "$RUN_DIR/bin"
if [ -n "${WIPTER_MACHINE_ID:-}" ]; then
  # node-machine-id runs `cat /var/lib/dbus/machine-id /etc/machine-id || hostname`.
  printf '#!/bin/sh\necho %s\n' "$WIPTER_MACHINE_ID" > "$RUN_DIR/bin/hostname"
  chmod 0755 "$RUN_DIR/bin/hostname"
fi
unset WIPTER_MACHINE_ID

# Optional VNC view: x11vnc connects out to the viewer every 30 s until one
# session takes, and again after it ends. Its output (addresses) is dropped.
if [ -n "$VNC_VIEWER" ]; then
  vhost="${VNC_VIEWER%%:*}"; vport=5500
  [ "$vhost" = "$VNC_VIEWER" ] || vport="${VNC_VIEWER##*:}"
  # A tailnet IP is used as is; a name is looked up among the peers this node can see.
  if [[ "$vhost" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then vip="$vhost"
  else vip="$(ts ip -4 "$vhost" 2>/dev/null | head -n 1 || true)"; fi
  if ! [[ "$vip" =~ ^100\.[0-9.]+$ ]]; then
    warn "VNC: no tailnet device '$vhost' visible from here (offline, or the ACL doesn't let this node's tag reach it); no VNC this run"
    VNC_VIEWER=""
  fi
fi
if [ -n "$VNC_VIEWER" ]; then
  echo "::add-mask::$vip"
  ts status --json 2>/dev/null | jq -e --arg ip "$vip" '[.Peer[]? | .TailscaleIPs[]?] | index($ip)' >/dev/null \
    || warn "VNC: the viewer's device isn't among the peers this node can see: the ACL probably doesn't let this node's tag reach it"
  ( umask 077; printf '%s\n' "$WIPTER_VNC_PASSWORD" > "$RUN_DIR/vncpass" )
  unset WIPTER_VNC_PASSWORD
  ok "VNC: connecting out to $vhost:$vport every 30 s (a viewer listening there gets the app's screen)"
  # Reports the first failures, then every 20th, and each session (addresses masked).
  ( n=0
    while :; do
      if [ -S /tmp/.X11-unix/X99 ]; then
        t0=$(date +%s)
        if env -i PATH=/usr/bin:/bin HOME="$RUN_DIR" DISPLAY=:99 \
          "$B/graftcp" --not-ignore-local --select_proxy_mode only_socks5 --socks5 "$SOCKS_TS" -- \
          "$RT/bin/x11vnc" -display :99 -rfbport 0 -connect_or_exit "$vip:$vport" \
            -passwdfile "$RUN_DIR/vncpass" -nolookup -quiet > "$RUN_DIR/x11vnc.log" 2>&1 \
          && [ $(( $(date +%s) - t0 )) -gt 20 ]; then
          ok "VNC: a session ended ($(( ($(date +%s) - t0) / 60 )) min)"; n=0
        else
          n=$((n + 1))
          if [ "$n" -le 3 ] || [ $((n % 20)) -eq 0 ]; then
            warn "VNC: could not reach the viewer (try $n): $(grep -iE 'refused|timed out|unreach|fail|error' "$RUN_DIR/x11vnc.log" | tail -n 1 | sed -E 's/[0-9]+(\.[0-9]+){3}/<ip>/g' | cut -c1-160)"
          fi
        fi
      fi
      sleep 30
    done ) &
  PIDS+=("$!")
elif [ "$VNC_LISTEN" = 1 ]; then
  ( umask 077; printf '%s\n' "$WIPTER_VNC_PASSWORD" > "$RUN_DIR/vncpass" )
  unset WIPTER_VNC_PASSWORD
  ok "VNC: listening on port 5900; connect a viewer to $(ts status --json 2>/dev/null | jq -r '.Self.HostName // "this node"'):5900 over the tailnet"
  # tailscaled hands inbound tailnet connections to 127.0.0.1, so x11vnc
  # listens there only. Restarted if it exits; failures reported as above.
  ( n=0
    while :; do
      if [ -S /tmp/.X11-unix/X99 ]; then
        env -i PATH=/usr/bin:/bin HOME="$RUN_DIR" DISPLAY=:99 \
          "$RT/bin/x11vnc" -display :99 -localhost -rfbport 5900 -forever -shared \
            -passwdfile "$RUN_DIR/vncpass" -nolookup -quiet > "$RUN_DIR/x11vnc.log" 2>&1 || true
        n=$((n + 1))
        if [ "$n" -le 3 ] || [ $((n % 20)) -eq 0 ]; then
          warn "VNC: x11vnc stopped (try $n): $(grep -iE 'in use|fail|error|refused' "$RUN_DIR/x11vnc.log" | tail -n 1 | sed -E 's/[0-9]+(\.[0-9]+){3}/<ip>/g' | cut -c1-160)"
        fi
      fi
      sleep 30
    done ) &
  PIDS+=("$!")
else
  unset WIPTER_VNC_PASSWORD
fi
# A clean environment: nothing from the job reaches the app but the login, which
# stays in the environment (not on a command line, where ps would show it).
start_app() {
  local v d="$RUN_DIR" r="$RT"   # RUN_DIR may be exported: keep it before the unset
  for v in $(compgen -e); do
    case "$v" in WIPTER_EMAIL|WIPTER_PASSWORD) ;; *) unset "$v" 2>/dev/null || true ;; esac
  done
  export PATH="$d/bin:/usr/local/bin:/usr/bin:/bin" HOME="$d/home" TMPDIR="$d/tmp" \
    LANG=C.UTF-8 FONTCONFIG_FILE="$r/fonts.conf" XDG_DATA_DIRS="$r/share" GIO_MODULE_DIR="$r/gio-modules" \
    WIPTER_APP="$r/app/wipter-app.bin" WIPTER_XVFB="$r/bin/Xvfb" WIPTER_XKB_DIR="$r/share/X11/xkb" \
    WIPTER_SCREEN=1024x800x16
  exec "${GRAFT[@]}" -- timeout -k 30 "$1" "$r/wipter-entry"
}
show() {
  awk '{ gsub(/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/, "<ip>"); print "    " $0; fflush() }' | tee -a "$RUN_DIR/app.log"
}
quick_exits=0
while :; do
  remaining=$(( DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 60 ] || break
  ! port_busy "$APP_SOCKS_PORT" || fail "port $APP_SOCKS_PORT on 127.0.0.1 was taken"
  started=$(date +%s)
  # A previous run's Xvfb was killed: its socket would look like a running one.
  rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
  ( start_app "$remaining" ) < /dev/null > >(show) 2>&1 &
  CPID=$!
  PIDS+=("$CPID")
  ok "app started for $(( remaining / 60 )) min"
  n=0
  while kill -0 "$CPID" 2>/dev/null; do
    sleep 60
    n=$((n + 1))
    # Never let the app run without the exit node set.
    if ! ts status --json 2>/dev/null | jq -e '.ExitNodeStatus != null' >/dev/null; then
      kill "$CPID" 2>/dev/null || true
      fail "the exit node is no longer set; app stopped"
    fi
    if [ $((n % 60)) -eq 0 ]; then
      if exit_node_ok; then s="online"; else s="OFFLINE (app traffic blocked)"; fi
      printf '[*] %s app up, exit node %s, %s min left\n' "$(date -u +%H:%M)" "$s" $(( (DEADLINE - $(date +%s)) / 60 ))
    fi
  done
  wait "$CPID" 2>/dev/null || true
  [ $(( DEADLINE - $(date +%s) )) -gt 60 ] || break
  grep -q 'sign-in failed 3 times' "$RUN_DIR/app.log" 2>/dev/null \
    && fail "sign-in keeps failing: check WIPTER_EMAIL / WIPTER_PASSWORD"
  if [ $(( $(date +%s) - started )) -lt 300 ]; then quick_exits=$((quick_exits + 1)); else quick_exits=0; fi
  [ "$quick_exits" -lt 5 ] || fail "the app keeps exiting within 5 minutes"
  warn "app exited early; restarting in 30 s"
  sleep 30
done
ok "run finished"

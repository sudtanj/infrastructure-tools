#!/usr/bin/env bash
# Runs stock Google Chrome, with the official Grass extension installed in its
# profile, for a set time inside a GitHub runner job on the Instabox machine
# (no Docker, no TUN device, no NET_ADMIN, no X server), with all of its
# traffic leaving through a Tailscale exit node. Built like wipter-bundle's
# run.sh in its open-network mode:
#
#   chrome --proxy-server--> tailscaled SOCKS5 (127.0.0.1:1058, userspace)
#     --> exit node --> internet
#   and, for anything Chrome sends past its proxy setting, graftcp sends every
#   connection of Chrome and its child processes (loopback aside) to that same
#   SOCKS5 port, DNS as DNS-over-TCP to 1.1.1.1. WebRTC may only use the proxy.
#
# Nothing goes out directly: the path is checked before Chrome starts (the IP
# seen through it must differ from this machine's own), and Chrome is stopped
# if the exit node is unset or stays offline for 10 minutes.
#
# Chrome runs from rt/, linked to /tmp/grass-rt (the path its loader and
# libraries were relocated to), on the bundle's own Xvfb (:97, no window
# manager), with its profile in $RUN_DIR/home (the job saves and restores it).
# The extension and the Grass sign-in are done once by hand over VNC (see the
# README) and live in that profile. Ports differ from wipter-bundle's (1057,
# 1083, 2000, :99, 127.0.0.1:5900), so both can share the host network.
#
# Sandbox: Chrome runs with --no-sandbox by default, as wipter-bundle does.
# Its sandbox needs either the setuid chrome-sandbox helper (a downloaded file
# can't be setuid root) or unprivileged user namespaces, and it refuses to run
# as root at all; the runner's job container is the boundary, and Chrome only
# opens Grass and the Chrome Web Store. GRASS_SANDBOX=1 keeps Chrome's
# user-namespace sandbox when this user is not root and can create one
# (checked with unshare); otherwise it warns and falls back.
#
# Environment:
#   TS_AUTHKEY           Tailscale auth key (required)
#   TS_TAGS              tags to advertise (needed with an OAuth-minted key)
#   TS_EXIT_NODE         tag:name, a MagicDNS name or a Tailscale IPv4 (required)
#   RUN_SECONDS          how long to run (default 3600)
#   RUN_DIR              scratch dir: sockets, logs, Chrome's profile (default: a mktemp dir)
#   GRASS_CACHE_DIR      Chrome's HTTP cache, capped at 64 MB (default: $RUN_DIR/cache);
#                        point it off a RAM tmpfs to keep it out of the memory cap
#   GRASS_URL            page Chrome opens on start (default https://app.grass.io/)
#   GRASS_TZ             Chrome's timezone, to match the exit node (default Asia/Jakarta)
#   GRASS_DEBUG=1        show Chrome's own output (IPs, emails and tokens masked)
#   GRASS_SANDBOX=1      try Chrome's sandbox (see above)
#   VNC_LISTEN=1         x11vnc serves Chrome's screen on port 5900 of this node
#                        (tailnet name grass-instabox). Needs:
#   GRASS_VNC_PASSWORD   the password the viewer must give
#   TS_API_TOKEN         optional: a Tailscale API token allowed to write devices:
#                        earlier runs' grass-instabox nodes are removed and this
#                        node takes the name grass-instabox. With it:
#   TS_FIXED_IP          optional: the tailnet IPv4 this node then moves to
#
# VNC: x11vnc listens on 127.0.0.1:5901 only, and `tailscale serve` maps the
# node's tailnet port 5900 to it (wipter-bundle's x11vnc may hold
# 127.0.0.1:5900). --shields-up is off for it, and userspace tailscaled then
# also forwards other inbound tailnet connections to 127.0.0.1 on the same
# port, tailscaled's SOCKS5 port included: let the tailnet ACL allow only port
# 5900 on this node's tag.
set -euo pipefail

B="$(cd "$(dirname "$0")" && pwd)"
RUN_SECONDS="${RUN_SECONDS:-3600}"
SOCKS_TS="127.0.0.1:1058"
DISP=97
VNC_PORT=5900
VNC_LOCAL_PORT=5901
NODE_NAME=grass-instabox
GRASS_URL="${GRASS_URL:-https://app.grass.io/}"
GRASS_TZ="${GRASS_TZ:-Asia/Jakarta}"
RT=/tmp/grass-rt

step() { printf '%s\n' "[>] $*"; }
ok()   { printf '%s\n' "[+] $*"; }
warn() { printf '%s\n' "[!] $*" >&2; }
fail() { printf '%s\n' "[x] $*" >&2; exit 1; }

[ -n "${TS_AUTHKEY:-}" ] || fail "TS_AUTHKEY is required"
EXIT_NODE="${TS_EXIT_NODE:-}"
[[ "$EXIT_NODE" =~ ^tag:[A-Za-z0-9][A-Za-z0-9_-]*$ || "$EXIT_NODE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "TS_EXIT_NODE must be tag:name, a MagicDNS name or a Tailscale IPv4"
[[ "$RUN_SECONDS" =~ ^[0-9]+$ ]] || fail "RUN_SECONDS must be a number"
[[ "$GRASS_URL" =~ ^https://[^[:space:]]+$ ]] || fail "GRASS_URL must be an https URL"
[ "$(uname -m)" = x86_64 ] || fail "x86_64 only"
VNC_LISTEN="${VNC_LISTEN:-}"
[ "$VNC_LISTEN" != 1 ] || [ -n "${GRASS_VNC_PASSWORD:-}" ] || fail "VNC_LISTEN is set but GRASS_VNC_PASSWORD is not"
for t in curl jq timeout; do command -v "$t" >/dev/null || fail "$t is required"; done

# The relocated Chrome must sit at /tmp/grass-rt, and Xvfb finds xkbcomp in /tmp/gxb.
link() {
  if [ -e "$2" ] || [ -L "$2" ]; then
    [ "$(readlink "$2" 2>/dev/null)" = "$1" ] || fail "$2 exists and is not this bundle's"
  else
    ln -s "$1" "$2"
  fi
}
link "$B/rt" "$RT"
link "$RT/bin" /tmp/gxb
[ -x "$RT/chrome/chrome" ] && [ -x "$RT/bin/Xvfb" ] || fail "the bundle is incomplete"
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
for p in "${SOCKS_TS##*:}" "$VNC_LOCAL_PORT"; do
  ! port_busy "$p" || fail "port $p on 127.0.0.1 is already in use (another job on this machine?)"
done
[ ! -S "/tmp/.X11-unix/X$DISP" ] || ! pgrep -f "Xvfb :$DISP " >/dev/null 2>&1 \
  || fail "display :$DISP is already in use (another job on this machine?)"

RUN_DIR="${RUN_DIR:-$(mktemp -d)}"
mkdir -p "$RUN_DIR"
cd "$RUN_DIR"
SOCK="$RUN_DIR/tailscaled.sock"
PROFILE="$RUN_DIR/home/chrome-profile"
CACHE_DIR="${GRASS_CACHE_DIR:-$RUN_DIR/cache}"
ts() { "$B/tailscale" --socket="$SOCK" "$@"; }
DEADLINE=$(( $(date +%s) + RUN_SECONDS ))

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  # Chrome outlives graftcp if that is killed first: stop it by its profile dir.
  pkill -TERM -f -- "--user-data-dir=$PROFILE" 2>/dev/null && sleep 5 || true
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
  if ts up --authkey="$TS_AUTHKEY" "${tag_args[@]}" --hostname="$NODE_NAME" \
       --accept-dns=false --accept-routes=false "$shields" --timeout=90s >/dev/null 2>&1; then
    joined=1; break
  fi
  sleep 5
done
unset TS_AUTHKEY
[ "$joined" = 1 ] || fail "could not join the tailnet (key rejected or expired?)"
ok "joined the tailnet as $(ts status --json 2>/dev/null | jq -r '.Self.HostName // "?"')"

# Same name and IP every run (see wipter-bundle's run.sh): with an API token
# this node removes earlier runs' grass-instabox nodes, takes the name back and
# moves to TS_FIXED_IP, before Chrome starts.
tsapi() { curl -fsS --max-time 20 -H "Authorization: Bearer $TS_API_TOKEN" "$@"; }
NAME_RE="^$NODE_NAME(-[0-9]+)?\$"
claim_node() {
  local api=https://api.tailscale.com/api/v2 self devs old n=0
  self="$(ts status --json 2>/dev/null | jq -r '.Self.ID // empty')"
  [ -n "$self" ] || { warn "node: this node's ID is unknown"; return 1; }
  devs="$(tsapi "$api/tailnet/-/devices")" \
    || { warn "node: could not list devices (the OAuth client needs the Devices Core write scope)"; return 1; }
  for old in $(jq -r --arg self "$self" --arg re "$NAME_RE" '.devices[]? | select(.nodeId != $self and (.tags // []) != []
      and ((.hostname // "") | test($re))) | .nodeId' <<< "$devs"); do
    tsapi -X DELETE "$api/device/$old" >/dev/null && n=$((n + 1)) || warn "node: could not remove an earlier run's node"
  done
  [ "$n" = 0 ] || ok "node: removed $n earlier run(s)' node(s)"
  tsapi -X POST -H 'Content-Type: application/json' -d "{\"name\":\"$NODE_NAME\"}" "$api/device/$self/name" >/dev/null \
    && ok "node: named $NODE_NAME" || warn "node: could not take the name $NODE_NAME"
  [ -n "${TS_FIXED_IP:-}" ] || return 0
  [[ "$TS_FIXED_IP" =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { warn "TS_FIXED_IP must be a tailnet IPv4 (100.x.y.z); ignored"; return 0; }
  if jq -e --arg ip "$TS_FIXED_IP" --arg self "$self" --arg re "$NAME_RE" \
       '[.devices[]? | select(.nodeId != $self and ((.addresses // []) | index($ip)) and
         ((.hostname // "") | test($re) | not))] | length > 0' <<< "$devs" >/dev/null; then
    warn "fixed IP: another device of the tailnet holds it; not taken"; return 1
  fi
  tsapi -X POST -H 'Content-Type: application/json' -d "{\"ipv4\":\"$TS_FIXED_IP\"}" "$api/device/$self/ip" >/dev/null \
    || { warn "fixed IP: Tailscale refused to set it"; return 1; }
  for _ in $(seq 1 30); do
    [ "$(ts ip -4 2>/dev/null)" = "$TS_FIXED_IP" ] && { ok "fixed IP: this node has its usual tailnet IP"; return 0; }
    sleep 2
  done
  warn "fixed IP: set, but this node hasn't picked it up yet"
}
if [ -n "${TS_API_TOKEN:-}" ]; then
  claim_node || warn "node: keeping the name and IP Tailscale gave this run"
fi
unset TS_API_TOKEN

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
exit_node_set() { ts status --json 2>/dev/null | jq -e '.ExitNodeStatus != null' >/dev/null; }
exit_node_ok() { ts status --json 2>/dev/null | jq -e '.ExitNodeStatus.Online == true' >/dev/null; }
for _ in $(seq 1 30); do exit_node_ok && break; sleep 2; done
exit_node_ok || fail "the exit node is not online"
ok "exit node in use"

# 3. Chrome's two paths, checked: its proxy setting (tailscaled's SOCKS5 port)
# and graftcp (for anything that bypasses it). Both must leave from an IP
# other than this machine's.
GRAFT=("$B/graftcp" --select_proxy_mode only_socks5 --socks5 "$SOCKS_TS"
       --enable-dns --dns-server 1.1.1.1:53 --enable-udp)
direct_ip="$(curl -fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
proxy_ip="$(curl -fsS --max-time 30 --socks5-hostname "$SOCKS_TS" https://api.ipify.org 2>/dev/null || true)"
graft_ip="$("${GRAFT[@]}" -- curl -fsS --max-time 30 https://api.ipify.org 2>/dev/null || true)"
for ip in "$direct_ip" "$proxy_ip" "$graft_ip"; do [ -z "$ip" ] || echo "::add-mask::$ip"; done
[[ "$proxy_ip" =~ ^[0-9.]+$ ]] || fail "nothing gets out through tailscaled's SOCKS5 port and the exit node"
[[ "$graft_ip" =~ ^[0-9.]+$ ]] || fail "nothing gets out through graftcp (ptrace blocked?)"
[ "$proxy_ip" != "$direct_ip" ] && [ "$graft_ip" != "$direct_ip" ] \
  || fail "traffic leaves from this machine's IP, not the exit node"
ok "Chrome's paths leave through the exit node (IPs not printed)"

# 4. Sandbox choice (see the header).
SANDBOX_ARGS=(--no-sandbox)
if [ "${GRASS_SANDBOX:-}" = 1 ]; then
  if [ "$(id -u)" != 0 ] && command -v unshare >/dev/null && unshare -U true 2>/dev/null; then
    SANDBOX_ARGS=(); ok "sandbox: Chrome's user-namespace sandbox is on"
  else
    warn "sandbox: root, or no unprivileged user namespaces here; Chrome runs with --no-sandbox"
  fi
fi

# 5. The display, kept up for the whole run (Chrome restarts reuse it).
mkdir -p "$RUN_DIR/home" "$RUN_DIR/tmp" "$PROFILE" "$CACHE_DIR"
if [ ! -d /tmp/.X11-unix ]; then mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix 2>/dev/null || true; fi
XPID=""
start_x() {
  rm -f "/tmp/.X$DISP-lock" "/tmp/.X11-unix/X$DISP"
  env -i PATH=/usr/bin:/bin HOME="$RUN_DIR/home" "$RT/bin/Xvfb" ":$DISP" -screen 0 1920x1080x24 \
    -nolisten tcp -noreset -extension GLX -xkbdir "$RT/share/X11/xkb" > "$RUN_DIR/xvfb.log" 2>&1 &
  XPID=$!; PIDS+=("$XPID")
  for _ in $(seq 1 50); do [ -S "/tmp/.X11-unix/X$DISP" ] && return 0; sleep 0.2; done
  fail "Xvfb did not start"
}
start_x

# Optional VNC: x11vnc on 127.0.0.1:5901, tailnet port 5900 mapped to it.
if [ "$VNC_LISTEN" = 1 ]; then
  ( umask 077; printf '%s\n' "$GRASS_VNC_PASSWORD" > "$RUN_DIR/vncpass" )
  unset GRASS_VNC_PASSWORD
  if timeout 30 "$B/tailscale" --socket="$SOCK" serve --bg --tcp "$VNC_PORT" "tcp://127.0.0.1:$VNC_LOCAL_PORT" >/dev/null 2>&1; then
    ok "VNC: connect a viewer to $NODE_NAME:$VNC_PORT over the tailnet"
  else
    warn "VNC: tailscale serve refused the port mapping; reach this node on port $VNC_LOCAL_PORT instead"
  fi
  # Restarted if it exits; the first failures and every 20th are reported (addresses masked).
  ( n=0
    while :; do
      if [ -S "/tmp/.X11-unix/X$DISP" ]; then
        env -i PATH=/usr/bin:/bin HOME="$RUN_DIR" DISPLAY=":$DISP" \
          "$RT/bin/x11vnc" -display ":$DISP" -localhost -rfbport "$VNC_LOCAL_PORT" -forever -shared \
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
  unset GRASS_VNC_PASSWORD
fi

# 6. Chrome, until the deadline (timeout runs inside graftcp and stops it with
# SIGTERM, so it shuts down cleanly and writes its profile). Restarted if it
# stops early. A clean environment: nothing from the job reaches Chrome.
CHROME_ARGS=(
  "${SANDBOX_ARGS[@]}"
  --user-data-dir="$PROFILE"
  --proxy-server="socks5://$SOCKS_TS"
  --force-webrtc-ip-handling-policy=disable_non_proxied_udp
  --password-store=basic
  --ozone-platform=x11
  # Look like an ordinary desktop Chrome to bot checks (Cloudflare Turnstile on
  # the Grass sign-in fails without these): WebGL through Chrome's own software
  # renderer instead of no GPU at all, a full-HD screen with a maximized window,
  # and a language to match. The timezone is set in start_chrome.
  --use-angle=swiftshader
  --enable-unsafe-swiftshader
  --start-maximized
  --lang=en-US
  --disable-dev-shm-usage
  --no-first-run
  --no-default-browser-check
  --hide-crash-restore-bubble
  # Memory: the Instabox job is capped at 1.5 GB, tmpfs included. One small
  # cache, fewer renderer processes, and no background downloads of components
  # and models.
  --disk-cache-dir="$CACHE_DIR"
  --disk-cache-size=67108864
  --renderer-process-limit=3
  --disable-component-update
  --disable-features=Translate,MediaRouter,OptimizationHints,OptimizationGuideModelDownloading,OptimizationHintsFetching
)
if [ "${GRASS_DEBUG:-}" = 1 ]; then CHROME_ARGS+=(--enable-logging=stderr); else CHROME_ARGS+=(--log-level=3); fi
start_chrome() {
  local v d="$RUN_DIR" r="$RT" url="$GRASS_URL" tz="$GRASS_TZ"   # these may be exported: kept before the unset
  for v in $(compgen -e); do unset "$v" 2>/dev/null || true; done
  export PATH="/usr/local/bin:/usr/bin:/bin" HOME="$d/home" TMPDIR="$d/tmp" LANG=C.UTF-8 DISPLAY=":$DISP" TZ="$tz" \
    FONTCONFIG_FILE="$r/fonts.conf" XDG_DATA_DIRS="$r/share" GIO_MODULE_DIR="$r/gio-modules" \
    GDK_PIXBUF_MODULE_FILE="$r/gdk-pixbuf-loaders.cache" GTK_IM_MODULE_FILE="$r/gtk-immodules.cache" \
    GSETTINGS_BACKEND=memory
  exec "${GRAFT[@]}" -- timeout -k 30 "$1" "$r/chrome/chrome" "${CHROME_ARGS[@]}" "$url"
}
show() {
  sed -u -E 's/[0-9]+(\.[0-9]+){3}/<ip>/g; s/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+/<email>/g;
    s/eyJ[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*/<token>/g; s/[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}/<id>/g;
    s/[A-Za-z0-9_-]{32,}/<token>/g; s/^/    chrome: /'
}
quick_exits=0
offline=0
while :; do
  remaining=$(( DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 60 ] || break
  kill -0 "$XPID" 2>/dev/null || { warn "Xvfb had stopped; starting it again"; start_x; }
  # A profile restored from another run, or a killed Chrome, leaves its lock behind.
  rm -f "$PROFILE"/Singleton*
  started=$(date +%s)
  if [ "${GRASS_DEBUG:-}" = 1 ]; then
    ( start_chrome "$remaining" ) < /dev/null > >(show) 2>&1 &
  else
    ( start_chrome "$remaining" ) < /dev/null > "$RUN_DIR/chrome.log" 2>&1 &
  fi
  CPID=$!
  PIDS+=("$CPID")
  ok "Chrome started for $(( remaining / 60 )) min"
  n=0
  while kill -0 "$CPID" 2>/dev/null; do
    sleep 60
    n=$((n + 1))
    # Never let Chrome run without the exit node.
    if ! exit_node_set; then
      kill "$CPID" 2>/dev/null || true
      fail "the exit node is no longer set; Chrome stopped"
    fi
    if exit_node_ok; then offline=0; else offline=$((offline + 1)); fi
    if [ "$offline" -ge 10 ]; then
      kill "$CPID" 2>/dev/null || true
      fail "the exit node has been offline for 10 minutes; Chrome stopped"
    fi
    if [ $((n % 60)) -eq 0 ]; then
      if [ "$offline" = 0 ]; then s="online"; else s="OFFLINE (traffic blocked)"; fi
      printf '[*] %s Chrome up, exit node %s, %s min left\n' "$(date -u +%H:%M)" "$s" $(( (DEADLINE - $(date +%s)) / 60 ))
    fi
  done
  wait "$CPID" 2>/dev/null || true
  [ $(( DEADLINE - $(date +%s) )) -gt 60 ] || break
  if [ $(( $(date +%s) - started )) -lt 300 ]; then quick_exits=$((quick_exits + 1)); else quick_exits=0; fi
  [ "$quick_exits" -lt 5 ] || fail "Chrome keeps exiting within 5 minutes (GRASS_DEBUG=1 shows its output)"
  warn "Chrome exited early; restarting in 30 s"
  sleep 30
done
ok "run finished"

#!/bin/bash
# Integration test of the host firewall with real packets: network namespaces stand in for the
# board, a LAN/internet client and a tailnet peer, the board loads userpatches/overlay/nftables.conf
# and runs an HTTP server, and every source either gets an answer or is dropped as intended.
# Needs root (ip netns, nft), python3 and curl. Cleans up after itself.

set -euo pipefail

RULES="$(cd "$(dirname "$0")/.." && pwd)/userpatches/overlay/nftables.conf"
B=opi-fw-board C=opi-fw-client T=opi-fw-ts
FAILED=0

cleanup() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null
  for ns in "$B" "$C" "$T"; do ip netns del "$ns" 2>/dev/null || true; done
}
trap cleanup EXIT
cleanup

for ns in "$B" "$C" "$T"; do ip netns add "$ns"; ip -n "$ns" link set lo up; done

# board eth0 <-> client: one link carrying LAN, internet and CGNAT-looking addresses
veth() {  # name-in-ns1 ns1 name-in-ns2 ns2 (temporary names, so nothing clashes with the host)
  ip link add opi-fw-a type veth peer name opi-fw-b
  ip link set opi-fw-a netns "$2"; ip -n "$2" link set opi-fw-a name "$1"
  ip link set opi-fw-b netns "$4"; ip -n "$4" link set opi-fw-b name "$3"
}
veth eth0 "$B" eth0 "$C"
ip -n "$B" addr add 192.168.50.1/24 dev eth0
ip -n "$B" addr add 203.0.113.1/24 dev eth0
ip -n "$B" addr add 100.100.1.1/24 dev eth0
ip -n "$B" addr add fd00:50::1/64 dev eth0 nodad
ip -n "$B" addr add 2001:db8:50::1/64 dev eth0 nodad
ip -n "$C" addr add 192.168.50.2/24 dev eth0
ip -n "$C" addr add 203.0.113.2/24 dev eth0
ip -n "$C" addr add 100.100.1.2/24 dev eth0
ip -n "$C" addr add fd00:50::2/64 dev eth0 nodad
ip -n "$C" addr add 2001:db8:50::2/64 dev eth0 nodad
# board tailscale0 <-> tailnet peer: anything arriving on tailscale0 is trusted
veth tailscale0 "$B" ts-peer "$T"
ip -n "$B" addr add 100.64.9.1/24 dev tailscale0
ip -n "$B" addr add 198.51.100.1/24 dev tailscale0
ip -n "$T" addr add 100.64.9.2/24 dev ts-peer
ip -n "$T" addr add 198.51.100.2/24 dev ts-peer
for ns in "$B" "$C"; do ip -n "$ns" link set eth0 up; done
ip -n "$B" link set tailscale0 up
ip -n "$T" link set ts-peer up

ip netns exec "$B" nft -f "$RULES"
ip netns exec "$B" python3 -m http.server 8080 --bind :: >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 50); do
  ip netns exec "$B" curl -s -o /dev/null -m 1 http://127.0.0.1:8080/ && break
  sleep 0.2
done

expect() {  # pass|drop netns source destination description
  local want="$1" ns="$2" src="$3" dst="$4" desc="$5" got=drop url
  url="http://${dst}:8080/"
  [[ "$dst" == *:* ]] && url="http://[${dst}]:8080/"
  ip netns exec "$ns" curl -s -o /dev/null -m 2 --interface "$src" "$url" && got=pass
  if [ "$got" = "$want" ]; then echo "ok - ${want}: ${desc}"; else echo "not ok - ${want}: ${desc} (got ${got})"; FAILED=1; fi
}

expect pass "$C" 192.168.50.2 192.168.50.1 "LAN IPv4"
expect pass "$C" fd00:50::2 fd00:50::1 "LAN IPv6 (ULA)"
expect drop "$C" 203.0.113.2 203.0.113.1 "public IPv4"
expect drop "$C" 2001:db8:50::2 2001:db8:50::1 "public IPv6"
expect drop "$C" 100.100.1.2 100.100.1.1 "CGNAT range outside tailscale0"
expect pass "$T" 100.64.9.2 100.64.9.1 "tailnet peer on tailscale0"
expect pass "$T" 198.51.100.2 198.51.100.1 "exit-node/subnet traffic on tailscale0"

# Replies to connections the board opens are allowed back in, even from the internet
ip netns exec "$C" python3 -m http.server 8081 --bind 203.0.113.2 >/dev/null 2>&1 &
CLIENT_PID=$!
sleep 1
if ip netns exec "$B" curl -s -o /dev/null -m 2 http://203.0.113.2:8081/; then
  echo "ok - pass: board's own outbound connection"
else
  echo "not ok - pass: board's own outbound connection"; FAILED=1
fi
kill "$CLIENT_PID" 2>/dev/null || true

if ip netns exec "$C" ping -c1 -W2 -I 203.0.113.2 203.0.113.1 >/dev/null; then
  echo "ok - pass: ICMP from the internet"
else
  echo "not ok - pass: ICMP from the internet"; FAILED=1
fi

# Reloading keeps Docker's tables
ip netns exec "$B" nft add table ip filter
ip netns exec "$B" nft add chain ip filter DOCKER
ip netns exec "$B" nft -f "$RULES"
if ip netns exec "$B" nft list chain ip filter DOCKER >/dev/null; then
  echo "ok - reload keeps other tables"
else
  echo "not ok - reload keeps other tables"; FAILED=1
fi
expect drop "$C" 203.0.113.2 203.0.113.1 "public IPv4 after reload"

exit "$FAILED"

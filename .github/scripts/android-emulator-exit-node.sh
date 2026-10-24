#!/usr/bin/env bash
# Sends the runner's internet traffic, and so the emulator's, through the
# tailnet exit node TAILSCALE_EXIT_NODE. Run just before the emulator starts:
# earlier, the system image download (about 1.5 GB) would go through it too.
# Fails if the egress IP doesn't change, so the emulator never starts on
# GitHub's IP.
set -euo pipefail

if [ "${USE_EXIT_NODE:-true}" != true ]; then
  echo "Exit node off for this run."
  exit 0
fi
target="$(printf '%s' "${TAILSCALE_EXIT_NODE:-}" | tr -d '[:space:]')"
if [ -z "$target" ]; then
  echo "::error title=No exit node::TAILSCALE_EXIT_NODE is not set; run with exit_node off to go without one."
  exit 1
fi
# Public log: the node and both egress IPs are masked.
echo "::add-mask::${target}"
# It reaches a command line, so only the forms Tailscale takes.
if [[ ! "$target" =~ ^(tag:)?[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "::error::TAILSCALE_EXIT_NODE must be 'tag:name', a MagicDNS name, or a Tailscale IPv4 address."
  exit 1
fi
before="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
[ -z "$before" ] || echo "::add-mask::${before}"
sudo tailscale set --exit-node="$target"
after=""
for _ in $(seq 1 12); do
  after="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
  [ -n "$after" ] && [ "$after" != "$before" ] && break
  sleep 5
done
[ -z "$after" ] || echo "::add-mask::${after}"
if [ -z "$after" ] || [ "$after" = "$before" ]; then
  echo "::error title=Exit node not in use::The egress IP did not change. Check the node is online and advertises an exit node."
  sudo tailscale set --exit-node= || true
  exit 1
fi
echo "Internet traffic now leaves through the exit node (fingerprint $(printf '%s' "$target" | sha256sum | cut -c1-12))."

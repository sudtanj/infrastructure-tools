#!/bin/bash
# bash-scripts/upsert-tailscale.sh
# Low-footprint Tailscale upsert for tiny VMs (e2-micro / COS).
#
# Env: TS_AUTHKEY, TS_HOSTNAME, TS_BIN_DIR, TS_EXTRA_ARGS,
#      TS_CHECK_MINUTES (default 720), FORCE=1 (skip the check interval)

set -euo pipefail

# Run this script itself at the lowest CPU/IO priority (best effort)
renice -n 19 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c3 -p $$ >/dev/null 2>&1 || true

# Skip sudo (extra process) when already root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

TS_BIN_DIR="${TS_BIN_DIR:-}"
TS_DEFAULT_BIN_DIR="/var/lib/docker/tailscale-bin"   # boot disk: persistent, no RAM
TS_STATE_DIR="/var/lib/tailscale"
TS_SOCKET="/run/tailscale/tailscaled.sock"
TS_UNIT="/etc/systemd/system/tailscaled.service"
TS_CACHE_DIR="/var/cache/tailscale"
TS_HOSTNAME="${TS_HOSTNAME:-gcp-free-tier-vm}"

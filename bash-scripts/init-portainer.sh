#!/bin/bash
# bash-scripts/init-portainer.sh
# Idempotent script to deploy or update Portainer CE to the latest version.

set -euo pipefail

PORTAINER_SNAPSHOT_INTERVAL="${PORTAINER_SNAPSHOT_INTERVAL:-15m}"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

status "init portainer start"

# ---------------------------------------------------------------------------
# 1. Cleanup old Portainer container
# ---------------------------------------------------------------------------
step "cleaning up existing portainer container"
docker rm -f portainer 2>/dev/null || true
ok "cleanup done"

# ---------------------------------------------------------------------------
# 2. Ensure persistent volume exists
# ---------------------------------------------------------------------------
step "ensuring portainer_data volume exists"
docker volume create portainer_data >/dev/null
ok "volume ready"

# ---------------------------------------------------------------------------
# 3. Pull latest Portainer image
# ---------------------------------------------------------------------------
step "pulling latest portainer/portainer-ce image"
docker pull portainer/portainer-ce:latest >/dev/null 2>&1 || fail "failed to pull portainer image"
ok "image pulled"

# ---------------------------------------------------------------------------
# 4. Deploy Portainer CE container
# ---------------------------------------------------------------------------
step "starting portainer container"
docker run -d --name portainer --restart always \
  -p 9000:9000 -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  --cpus 0.10 --memory 128m \
  --log-driver json-file --log-opt max-size=5m --log-opt max-file=2 \
  portainer/portainer-ce:latest \
  --snapshot-interval "${PORTAINER_SNAPSHOT_INTERVAL}" \
  >/dev/null 2>&1 || fail "failed to start portainer container"

sleep 3

STATE=$(docker inspect -f '{{.State.Status}}' portainer 2>/dev/null || echo "missing")
if [ "$STATE" != "running" ]; then
  warn "portainer state: ${STATE}"
  docker logs --tail 30 portainer >&2 || true
  fail "portainer container not running"
fi

ok "portainer is up and running"

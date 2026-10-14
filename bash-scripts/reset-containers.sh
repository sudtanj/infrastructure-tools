#!/bin/bash
# bash-scripts/reset-containers.sh
# Stop and remove every running Docker container. Volumes are kept: no `-v`, no `volume rm`, no prune,
# so re-running the init-*.sh scripts afterwards brings the services back with their data.
# Containers that were already stopped are left alone.
#
# Env: STOP_TIMEOUT (default 20) = seconds docker waits for a graceful stop before SIGKILL

set -euo pipefail

STOP_TIMEOUT="${STOP_TIMEOUT:-20}"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

# Skip sudo when already root or when the user can reach the docker socket directly
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  sudo docker info >/dev/null 2>&1 || fail "cannot reach the docker daemon"
  DOCKER="sudo docker"
fi

status "reset-containers start"

mapfile -t IDS < <($DOCKER ps -q)
if [ "${#IDS[@]}" -eq 0 ]; then
  ok "no running containers"
  exit 0
fi

status "running containers: ${#IDS[@]}"
$DOCKER ps --format '{{.Names}} ({{.Image}})' | sed 's/^/[*]   /'

VOLS_BEFORE=$($DOCKER volume ls -q | wc -l)

step "stopping (timeout ${STOP_TIMEOUT}s)"
$DOCKER stop -t "$STOP_TIMEOUT" "${IDS[@]}" >/dev/null || warn "some containers did not stop cleanly"

# Plain `rm` (no -v): named and anonymous volumes both survive
step "removing"
$DOCKER rm -f "${IDS[@]}" >/dev/null || warn "some containers could not be removed"

LEFT=0
for id in "${IDS[@]}"; do
  if $DOCKER inspect "$id" >/dev/null 2>&1; then LEFT=$((LEFT + 1)); fi
done
VOLS_AFTER=$($DOCKER volume ls -q | wc -l)

echo "[>] summary"
echo "[*] containers removed: $(( ${#IDS[@]} - LEFT )) of ${#IDS[@]}"
echo "[*] volumes: ${VOLS_BEFORE} before, ${VOLS_AFTER} after"
[ "$VOLS_AFTER" -ge "$VOLS_BEFORE" ] || fail "volume count dropped"
[ "$LEFT" -eq 0 ] || fail "${LEFT} container(s) could not be removed"
ok "reset-containers done"

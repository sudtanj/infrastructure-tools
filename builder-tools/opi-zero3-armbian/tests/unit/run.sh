#!/bin/bash
# Unit tests: runs the bats suites in a throwaway Debian container of the image's release, so
# opi-provision and the configs meet the same openssh, nftables, apt and shadow versions as
# on the board. The container needs NET_ADMIN for nft (it only touches its own netns).
#
#   tests/unit/run.sh                    from anywhere; uses docker
#   OPI_UNIT_IN_CONTAINER=1 run.sh       (internal) the part that runs inside the container

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

if [ "${OPI_UNIT_IN_CONTAINER:-}" != 1 ]; then
  . <(sed 's|\r$||' "${ROOT}/variables" | grep -E '^RELEASE=')
  exec docker run --rm --cap-add NET_ADMIN -e OPI_UNIT_IN_CONTAINER=1 \
    -v "${ROOT}:/src:ro" "debian:${RELEASE:-trixie}" /src/tests/unit/run.sh
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# systemd only for its groups (systemd-journal); it is never started
apt-get install -y -qq --no-install-recommends bats openssh-server nftables unattended-upgrades \
  python3 python3-yaml tzdata systemd perl >/dev/null
ssh-keygen -A >/dev/null
mkdir -p /run/sshd

bats --print-output-on-failure /src/tests/unit/*.bats

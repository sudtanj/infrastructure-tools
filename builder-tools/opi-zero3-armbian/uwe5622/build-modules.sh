#!/bin/bash
# Builds the uwe5622-mainline modules (uwe5622_bsp_sdio, sprdwl_ng, sprdbt_tty) out of tree
# against a prepared kernel build directory, natively (run it on arm64), and checks them:
# modpost resolves every symbol against the kernel's Module.symvers (no KBUILD_MODPOST_WARN),
# and each module's vermagic starts with the kernel's release.
#
#   build-modules.sh <driver source> <kernel build dir> <out dir>
#
# The build dir is Armbian's linux-headers package installed on the CI runner (its postinst
# compiles the host tools and restores the kernel's build-time config) or Debian's
# linux-headers-<ver> for the simulation kernel. <out dir> gets the stripped .ko files,
# build.log, the kernel's Module.symvers (kernel.symvers) and MANIFEST.

set -euo pipefail

SRC_IN="$(cd "$1" && pwd)"
KDIR="$(cd "$2" && pwd)"
OUT="$3"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
MODULES=(unisocwcn/uwe5622_bsp_sdio.ko unisocwifi/sprdwl_ng.ko tty-sdio/sprdbt_tty.ko)

[ -s "${KDIR}/include/config/kernel.release" ] || { echo "no include/config/kernel.release in ${KDIR}" >&2; exit 1; }
[ -s "${KDIR}/Module.symvers" ] || { echo "no Module.symvers in ${KDIR}: symbols could not be checked" >&2; exit 1; }
[ -x "${KDIR}/scripts/mod/modpost" ] || { echo "${KDIR} is not prepared (no scripts/mod/modpost)" >&2; exit 1; }
KREL="$(cat "${KDIR}/include/config/kernel.release")"

# Build in a copy: the source may be read-only, and a rebuild must start clean
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
cp -a "${SRC_IN}/." "$BUILD/"
rm -rf "${BUILD}/.git"

# The compiler the kernel was really built with: include/config/auto.conf is the build-time config
# (.config may have been re-evaluated with the local compiler, e.g. by Armbian's headers postinst).
# Its flags (-fmin-function-alignment, ...) need the same major version: gcc-<major> when present.
conf="${KDIR}/include/config/auto.conf"
kgcc="$(sed -n 's/^CONFIG_GCC_VERSION=//p' "$conf")"
if [ -z "${CC:-}" ] && [ "${kgcc:-0}" -gt 0 ] && command -v "gcc-$((kgcc / 10000))" >/dev/null; then CC="gcc-$((kgcc / 10000))"; fi
CC="${CC:-gcc}"
echo "# kernel ${KREL}, built with: $(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"$/\1/p' "$conf")"
echo "# compiler here: ${CC}: $("$CC" --version | head -n1)"
set +e
make -C "$KDIR" M="$BUILD" -j"$(nproc)" CC="$CC" \
  CONFIG_AW_WIFI_DEVICE_UWE5622=y CONFIG_WLAN_UWE5622=m CONFIG_TTY_OVERY_SDIO=m modules \
  > "${OUT}/build.log" 2>&1
status=$?
set -e
cat "${OUT}/build.log"
[ "$status" -eq 0 ] || { echo "module build failed (${status})" >&2; exit 1; }
if grep -E 'WARNING: modpost: .*(undefined|not exported)' "${OUT}/build.log"; then
  echo "modpost could not resolve every symbol against the kernel" >&2; exit 1
fi

failed=0
{
  echo "kernel_release=${KREL}"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${OUT}/MANIFEST"
for m in "${MODULES[@]}"; do
  ko="${BUILD}/${m}"
  [ -s "$ko" ] || { echo "not built: ${m}" >&2; failed=1; continue; }
  # As Armbian and Debian install theirs (INSTALL_MOD_STRIP): no debug info on the SD card
  strip --strip-debug "$ko"
  vermagic="$(modinfo -F vermagic "$ko")"
  if [ "${vermagic%% *}" = "$KREL" ]; then
    echo "ok - $(basename "$ko") vermagic: ${vermagic}"
  else
    echo "not ok - $(basename "$ko") vermagic '${vermagic}' is not for ${KREL}" >&2; failed=1
  fi
  install -m 644 "$ko" "${OUT}/"
  echo "$(basename "$ko") $(sha256sum "$ko" | cut -d' ' -f1)" >> "${OUT}/MANIFEST"
done
cp "${KDIR}/Module.symvers" "${OUT}/kernel.symvers"
exit "$failed"

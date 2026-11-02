#!/bin/bash
# Makes the uwe5622-mainline variant of a built image: the modules from build-modules.sh go to
# /lib/modules/<ver>/updates/uwe5622/ and depmod runs for that kernel inside the image (natively:
# run it as root on arm64). updates/ wins over Armbian's in-tree modules of the same name, and it
# is per kernel version, so after an Armbian kernel upgrade the board falls back to Armbian's
# driver by itself. Nothing else in the image changes.
#
#   sudo make-image.sh <image.img.xz> <modules dir> <out.img.xz> [source description]

set -euo pipefail

IMG_IN="$1"
MODDIR="$(cd "$2" && pwd)"
IMG_OUT="$3"
SOURCE="${4:-uwe5622-mainline}"
WORK="$(mktemp -d)"
MNT="${WORK}/root"

cleanup() {
  for m in dev proc sys; do umount "${MNT}/${m}" 2>/dev/null || true; done
  umount "$MNT" 2>/dev/null || true
  if [ -n "${LOOP:-}" ]; then losetup -d "$LOOP" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

IMG="${WORK}/image.img"
xz -dc "$IMG_IN" > "$IMG"
LOOP="$(losetup --show -fP "$IMG")"
mkdir -p "$MNT"
mount "${LOOP}p1" "$MNT"

MODROOT=usr/lib/modules
[ -d "${MNT}/${MODROOT}" ] || MODROOT=lib/modules
mapfile -t kvers < <(find "${MNT}/${MODROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
[ "${#kvers[@]}" -eq 1 ] || { echo "expected one kernel in the image, found: ${kvers[*]}" >&2; exit 1; }
KVER="${kvers[0]}"
built_for="$(sed -n 's/^kernel_release=//p' "${MODDIR}/MANIFEST")"
[ "$built_for" = "$KVER" ] || { echo "modules are for ${built_for}, the image runs ${KVER}" >&2; exit 1; }

dest="${MNT}/${MODROOT}/${KVER}/updates/uwe5622"
install -d -m 755 "$dest"
for ko in uwe5622_bsp_sdio.ko sprdwl_ng.ko sprdbt_tty.ko; do
  install -m 644 "${MODDIR}/${ko}" "$dest/"
done
{
  echo "# uwe5622-mainline modules for ${KVER}, installed by the image build (not by a package)."
  echo "# They override Armbian's in-tree driver for this kernel only. To go back to Armbian's:"
  echo "#   sudo rm -r /lib/modules/\$(uname -r)/updates/uwe5622 && sudo depmod -a && sudo reboot"
  echo "source=${SOURCE}"
  cat "${MODDIR}/MANIFEST"
} > "${dest}/SOURCE"
chmod 644 "${dest}/SOURCE"

for m in dev proc sys; do mount --bind "/${m}" "${MNT}/${m}"; done
chroot "$MNT" depmod -a "$KVER"
echo "# modprobe in the image now resolves:"
chroot "$MNT" modprobe -S "$KVER" --show-depends sprdwl_ng | sed 's/^/#   /'
for m in dev proc sys; do umount "${MNT}/${m}"; done
umount "$MNT"
losetup -d "$LOOP"; LOOP=

xz -T0 -6 -c "$IMG" > "$IMG_OUT"
(cd "$(dirname "$IMG_OUT")" && sha256sum "$(basename "$IMG_OUT")" > "$(basename "$IMG_OUT").sha")
echo "# wrote ${IMG_OUT} ($(( $(stat -c %s "$IMG_OUT") / 1048576 )) MiB)"

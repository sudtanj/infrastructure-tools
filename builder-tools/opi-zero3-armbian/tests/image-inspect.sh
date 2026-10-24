#!/bin/bash
# Integration test of a built image, without booting it: the Orange Pi Zero 3 boot chain
# (U-Boot SPL where the H618 boot ROM looks for it, boot script, device tree, kernel, initrd),
# the board kernel's Docker support, the size budget, and opi-selfcheck --image run in the
# image's own root filesystem. Must run as root on an arm64 host (the chroot runs natively).
#
#   sudo tests/image-inspect.sh Armbian-...img.xz|.img
#   OPI_MAX_ROOTFS_MB   fail when the root filesystem uses more (default 1200)

set -euo pipefail

IMG_IN="$1"
MAX_MB="${OPI_MAX_ROOTFS_MB:-1200}"
WORK="$(mktemp -d)"
MNT="${WORK}/root"
FAILED=0
ok()   { echo "ok - $*"; }
fail() { echo "not ok - $*"; FAILED=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }

cleanup() {
  for m in dev/pts dev proc sys run; do umount "${MNT}/${m}" 2>/dev/null || true; done
  umount "$MNT" 2>/dev/null || true
  [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

if [[ "$IMG_IN" == *.xz ]]; then
  IMG="${WORK}/image.img"
  xz -dc "$IMG_IN" > "$IMG"
else
  IMG="$IMG_IN"
fi
echo "# image: $(basename "$IMG_IN"), $(( $(stat -c %s "$IMG") / 1048576 )) MiB raw"

# --- boot chain ---
# The H618 boot ROM loads an eGON image from 8 KiB on the SD card
magic="$(dd if="$IMG" bs=1 skip=$((8192 + 4)) count=8 status=none)"
[ "$magic" = "eGON.BT0" ] && ok "U-Boot SPL (eGON.BT0) at 8 KiB" || fail "U-Boot SPL (eGON.BT0) at 8 KiB (got '${magic}')"

LOOP="$(losetup --show -fP "$IMG")"
mkdir -p "$MNT"
mount "${LOOP}p1" "$MNT"

check "boot script /boot/boot.scr" test -s "${MNT}/boot/boot.scr"
check "/boot/armbianEnv.txt" test -s "${MNT}/boot/armbianEnv.txt"
check "kernel /boot/Image" test -s "${MNT}/boot/Image"
check "initrd /boot/uInitrd" test -s "${MNT}/boot/uInitrd"
dtb="$(find "${MNT}/boot/dtb/" -name 'sun50i-h618-orangepi-zero3.dtb' 2>/dev/null | head -n1)"
[ -n "$dtb" ] && ok "device tree sun50i-h618-orangepi-zero3.dtb" || fail "device tree sun50i-h618-orangepi-zero3.dtb"
if ls "${MNT}"/usr/lib/firmware/uwe5622/* >/dev/null 2>&1; then ok "Wi-Fi firmware (UWE5622)"; else fail "Wi-Fi firmware (UWE5622)"; fi
root_uuid="$(blkid -s UUID -o value "${LOOP}p1")"
if grep -q "^rootdev=UUID=${root_uuid}$" "${MNT}/boot/armbianEnv.txt"; then
  ok "armbianEnv rootdev matches the root partition"
else
  fail "armbianEnv rootdev matches the root partition ($(grep '^rootdev=' "${MNT}/boot/armbianEnv.txt" || echo none))"
fi
grep -q '^console=' "${MNT}/boot/armbianEnv.txt" && echo "# $(grep '^console=' "${MNT}/boot/armbianEnv.txt")"

# --- the board kernel can run Docker (subset of moby's check-config.sh) ---
kcfg="$(ls "${MNT}"/boot/config-* 2>/dev/null | head -n1)"
if [ -n "$kcfg" ]; then
  echo "# kernel: $(basename "$kcfg" | sed 's/^config-//')"
  # cgroup v2 + iptables-nft, as Docker uses them on Debian trixie
  for opt in NAMESPACES NET_NS PID_NS IPC_NS UTS_NS CGROUPS CGROUP_BPF CGROUP_CPUACCT CGROUP_FREEZER \
             CGROUP_SCHED CPUSETS MEMCG KEYS VETH BRIDGE BRIDGE_NETFILTER NF_NAT NF_TABLES NF_TABLES_INET \
             NFT_CT NFT_NAT NFT_MASQ NFT_COMPAT NETFILTER_XT_MATCH_ADDRTYPE NETFILTER_XT_MATCH_CONNTRACK \
             POSIX_MQUEUE OVERLAY_FS SECCOMP TUN; do
    if grep -qE "^CONFIG_${opt}=(y|m)$" "$kcfg"; then ok "kernel CONFIG_${opt}"; else fail "kernel CONFIG_${opt}"; fi
  done
else
  fail "kernel config /boot/config-* present"
fi

# --- size ---
used_mb="$(( $(df --output=used -B1 "$MNT" | tail -n1) / 1048576 ))"
echo "# root filesystem: ${used_mb} MiB used, $(chroot "$MNT" dpkg-query -W -f='.\n' 2>/dev/null | wc -l) packages"
[[ "$IMG_IN" == *.xz ]] && echo "# download (xz): $(( $(stat -c %s "$IMG_IN") / 1048576 )) MiB"
# (|| true: head closing the pipe early is not a failure)
echo "# largest packages (MiB installed):"
chroot "$MNT" dpkg-query -W -f='${Installed-Size}\t${Package}\n' 2>/dev/null | sort -rn | head -n 25 \
  | awk '{ printf "#   %7.1f  %s\n", $1 / 1024, $2 }' || true
echo "# largest directories (MiB):"
du -xm -d 4 "${MNT}/usr" "${MNT}/var" "${MNT}/opt" 2>/dev/null | sort -rn | head -n 25 \
  | sed "s|${MNT}||; s/^/#   /" || true
[ "$used_mb" -le "$MAX_MB" ] && ok "root filesystem <= ${MAX_MB} MiB" || fail "root filesystem <= ${MAX_MB} MiB (${used_mb})"

# --- the lockdown, checked by the image's own tools ---
for m in dev dev/pts proc sys; do mount --bind "/${m}" "${MNT}/${m}"; done
mount -t tmpfs tmpfs "${MNT}/run"
if chroot "$MNT" /usr/local/sbin/opi-selfcheck --image; then ok "opi-selfcheck --image"; else fail "opi-selfcheck --image"; fi

[ "$FAILED" -eq 0 ] && echo "# image inspection: all passed" || echo "# image inspection: FAILED"
exit "$FAILED"

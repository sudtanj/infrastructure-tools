#!/bin/bash
# Integration test of a built image, without booting it: the Orange Pi Zero 3 boot chain
# (U-Boot SPL where the H618 boot ROM looks for it, boot script, device tree, kernel, initrd),
# the board kernel's Docker support, the size budget, and opi-selfcheck --image run in the
# image's own root filesystem. Must run as root on an arm64 host (the chroot runs natively).
#
#   sudo tests/image-inspect.sh Armbian-...img.xz|.img
#   OPI_MAX_ROOTFS_MB   fail when the root filesystem uses more (default 900)
#   OPI_UWE5622_VARIANT armbian (default: Armbian's in-tree Wi-Fi driver) or mainline (uwe5622-mainline
#                       modules in /lib/modules/<ver>/updates/uwe5622, see uwe5622/make-image.sh)
#   OPI_UWE5622_SYMVERS the kernel's Module.symvers, for the symbol check when the image has no System.map

set -euo pipefail

IMG_IN="$1"
MAX_MB="${OPI_MAX_ROOTFS_MB:-900}"
VARIANT="${OPI_UWE5622_VARIANT:-armbian}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
MNT="${WORK}/root"
FAILED=0
ok()   { echo "ok - $*"; }
fail() { echo "not ok - $*"; FAILED=1; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }

cleanup() {
  for m in dev/pts dev proc sys run; do umount "${MNT}/${m}" 2>/dev/null || true; done
  umount "$MNT" 2>/dev/null || true
  if [ -n "${LOOP:-}" ]; then losetup -d "$LOOP" 2>/dev/null || true; fi
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

# --- Wi-Fi/Bluetooth driver (UWE5622): Armbian's in-tree one, or uwe5622-mainline in updates/ ---
for m in dev dev/pts proc sys; do mount --bind "/${m}" "${MNT}/${m}"; done
mount -t tmpfs tmpfs "${MNT}/run"
mods_root="${MNT}/usr/lib/modules"
[ -d "$mods_root" ] || mods_root="${MNT}/lib/modules"
KVER="$(find "$mods_root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)"
upd="${mods_root}/${KVER}/updates/uwe5622"
echo "# UWE5622 driver expected: ${VARIANT} (kernel ${KVER})"
# Firmware the driver loads (uwe5622-mainline docs/HARDWARE.md): chip firmware and board RF tuning
fw="${MNT}/usr/lib/firmware"
if [ -s "${fw}/uwe5622/wcnmodem.bin" ] || [ -s "${fw}/wcnmodem.bin" ]; then ok "firmware wcnmodem.bin"; else fail "firmware wcnmodem.bin"; fi
check "firmware wifi_2355b001_1ant.ini" test -s "${fw}/wifi_2355b001_1ant.ini"
# Bluetooth stays off with either driver: the overlay's blacklist, unchanged, still applies
check "Bluetooth blacklist unchanged" cmp -s "${HERE}/../userpatches/overlay/modprobe-blacklist.conf" \
  "${MNT}/etc/modprobe.d/opi-blacklist.conf"
bt_dep="$(chroot "$MNT" modprobe -S "$KVER" --show-depends sprdbt_tty 2>&1 || true)"
[[ "$bt_dep" == "install /bin/true"* ]] && ok "modprobe sprdbt_tty is a no-op" || fail "modprobe sprdbt_tty is a no-op (${bt_dep})"
wifi_dep="$(chroot "$MNT" modprobe -S "$KVER" --show-depends sprdwl_ng 2>&1 || true)"
printf '#   %s\n' "$wifi_dep"
grep -E '/(sprdwl_ng|sprdbt_tty|uwe5622_bsp_sdio)\.ko$' "${mods_root}/${KVER}/modules.builtin" >/dev/null 2>&1 \
  && fail "UWE5622 driver is a module, not built into the kernel" || ok "UWE5622 driver is a module, not built into the kernel"
case "$VARIANT" in
  armbian)
    check "no uwe5622-mainline modules (updates/uwe5622 absent)" test ! -e "$upd"
    if grep -qE '^insmod .*/kernel/.*/sprdwl_ng\.ko' <<< "$wifi_dep"; then ok "sprdwl_ng is Armbian's in-tree module"; else fail "sprdwl_ng is Armbian's in-tree module"; fi
    ;;
  mainline)
    sed 's/^/#   /' "${upd}/SOURCE" 2>/dev/null || true
    for ko in uwe5622_bsp_sdio sprdwl_ng sprdbt_tty; do
      check "updates/uwe5622/${ko}.ko" test -s "${upd}/${ko}.ko"
      vermagic="$(chroot "$MNT" modinfo -F vermagic "/lib/modules/${KVER}/updates/uwe5622/${ko}.ko" 2>/dev/null || true)"
      [ "${vermagic%% *}" = "$KVER" ] && ok "${ko} vermagic ${KVER}" || fail "${ko} vermagic ${KVER} (got '${vermagic}')"
    done
    for ko in uwe5622_bsp_sdio sprdwl_ng; do
      if grep -qE "^insmod /(usr/)?lib/modules/${KVER}/updates/uwe5622/${ko}\.ko" <<< "$wifi_dep"; then
        ok "modprobe sprdwl_ng loads ${ko} from updates/"
      else
        fail "modprobe sprdwl_ng loads ${ko} from updates/"
      fi
    done
    # Every symbol the modules import must come from this kernel or its modules
    smap="${MNT}/boot/System.map-${KVER}"
    if [ -s "$smap" ]; then
      depmod_args=(-F "/boot/System.map-${KVER}")
    elif [ -n "${OPI_UWE5622_SYMVERS:-}" ] && [ -s "$OPI_UWE5622_SYMVERS" ]; then
      cp "$OPI_UWE5622_SYMVERS" "${MNT}/run/kernel.symvers"
      depmod_args=(-E /run/kernel.symvers)
    else
      depmod_args=()
      fail "symbol check: neither /boot/System.map-${KVER} nor OPI_UWE5622_SYMVERS"
    fi
    if [ "${#depmod_args[@]}" -gt 0 ]; then
      unresolved="$(chroot "$MNT" depmod -n -e "${depmod_args[@]}" "$KVER" 2>&1 >/dev/null | grep -iE 'unknown symbol' | grep 'updates/uwe5622' || true)"
      [ -z "$unresolved" ] && ok "depmod -e: no unresolved symbols (${depmod_args[0]})" \
        || { fail "depmod -e: no unresolved symbols"; printf '#   %s\n' "$unresolved"; }
    fi
    if grep -q '^CONFIG_MODULE_SIG_FORCE=y' "${MNT}/boot/config-${KVER}" 2>/dev/null; then
      fail "kernel accepts unsigned modules (CONFIG_MODULE_SIG_FORCE is set)"
    else
      ok "kernel accepts unsigned modules"
    fi
    ;;
  *) fail "OPI_UWE5622_VARIANT must be armbian or mainline (${VARIANT})" ;;
esac
# The initrd must not carry a copy of the driver: an early load from there would bypass updates/
if [ -s "${MNT}/boot/initrd.img-${KVER}" ]; then
  if chroot "$MNT" lsinitramfs "/boot/initrd.img-${KVER}" 2>/dev/null | grep -qE '(sprdwl_ng|uwe5622_bsp_sdio|sprdbt_tty)\.ko'; then
    fail "initrd carries no UWE5622 module"
  else
    ok "initrd carries no UWE5622 module"
  fi
else
  echo "# no /boot/initrd.img-${KVER} to list (only uInitrd)"
fi
grep -vE '^[[:space:]]*(#|$)' "${MNT}/etc/modules" 2>/dev/null | sed 's/^/# \/etc\/modules: /' || true

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
if chroot "$MNT" /usr/local/sbin/opi-selfcheck --image; then ok "opi-selfcheck --image"; else fail "opi-selfcheck --image"; fi

[ "$FAILED" -eq 0 ] && echo "# image inspection: all passed" || echo "# image inspection: FAILED"
exit "$FAILED"

#!/bin/bash
# Boot simulation of the Orange Pi Zero 3 image in QEMU.
#
# QEMU has no Allwinner H618 machine and Armbian's sunxi64 kernel has no virtio or PL011
# drivers, so the board's boot chain can't run here (image-inspect.sh checks it statically).
# Everything above the kernel is the real image: its root filesystem boots unchanged with
# systemd on a `virt` machine shaped like the Zero 3 (4x Cortex-A53, 1 GiB RAM by default,
# TCG, so binaries built for newer CPUs would fault as they would on the board). The only
# addition is Debian's arm64 kernel of the image's release, unpacked outside dpkg's database.
#
# Scenario: first boot with a provisioning file -> provisioning, SSH and sudo, opi-selfcheck,
# Docker, a real deploy script from bash-scripts/ (init-dozzle.sh), memory left; then package
# upgrades (dist-upgrade + reinstalling every package next to our files), a reboot, and all of
# it checked again: updates from upstream must not break or undo the lockdown.
#
#   sudo tests/simulate.sh Armbian-...img.xz|.img
#   SIM_MEMORY (default 1024, MiB)  SIM_CPUS (4)  SIM_ACCEL (tcg; kvm uses -cpu host)
#   SIM_MIN_AVAILABLE_MB  fail when less memory is available with Docker + Dozzle up (default 400)
#   SIM_SKIP_UPGRADE=1    skip the upgrade + reboot round
#   SIM_METRICS_FILE=f    write the measurements (key=value) to f; SIM_SKIP_MEASURE=1 skips them
#                         (memory, boot timing of a plain reboot, idle CPU/wakeups, disk writes)
#   SIM_UWE5622_SRC=dir   build the uwe5622-mainline driver in dir against the simulation kernel
#                         and run SIM_UWE5622_ROUNDS (10) load/unload rounds without the chip

set -euo pipefail

IMG_IN="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
MEMORY="${SIM_MEMORY:-1024}"
CPUS="${SIM_CPUS:-4}"
ACCEL="${SIM_ACCEL:-tcg}"
MIN_AVAIL="${SIM_MIN_AVAILABLE_MB:-400}"
if [ -n "${SIM_METRICS_FILE:-}" ]; then : > "$SIM_METRICS_FILE"; fi
WORK="${SIM_WORK:-$(mktemp -d)}"
MNT="${WORK}/root"
PORT=2222
USER_NAME=opi
PASSWORD="sim-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
DOZZLE_PASSWORD="dz-$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9')"
FAILED=0
ok()   { echo "ok - $*"; }
fail() { echo "not ok - $*"; FAILED=1; }

unmount_image() {
  for m in dev/pts dev proc sys run; do umount "${MNT}/${m}" 2>/dev/null || true; done
  umount "$MNT" 2>/dev/null || true
  if [ -n "${LOOP:-}" ]; then losetup -d "$LOOP" 2>/dev/null || true; LOOP=; fi
}
stop_vm() {
  [ -s "${WORK}/qemu.pid" ] && kill "$(cat "${WORK}/qemu.pid")" 2>/dev/null || true
  rm -f "${WORK}/qemu.pid"
}
cleanup() {
  stop_vm
  unmount_image
  if [ "$FAILED" -ne 0 ] || [ -n "${SIM_KEEP_LOGS:-}" ]; then
    for f in "${WORK}"/console-*.log; do [ -f "$f" ] && { echo "::group::$(basename "$f")"; tail -n 300 "$f"; echo "::endgroup::"; }; done
  fi
  if [ -z "${SIM_WORK:-}" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

# --- prepare the disk: the image, grown like a real SD card ---
IMG="${WORK}/sim.img"
if [[ "$IMG_IN" == *.xz ]]; then xz -dc "$IMG_IN" > "$IMG"; else cp "$IMG_IN" "$IMG"; fi
truncate -s +4G "$IMG"
# The simulation kernel's modules need more room than the image leaves free: partition 1 grows
# by 1 GiB here; the other 3 GiB stay unallocated for armbian-resize-filesystem on first boot
read -r p_start p_sectors < <(partx -g -o START,SECTORS -n 1 "$IMG")
echo "${p_start},$((p_sectors + 2097152))" | sfdisk -q -N 1 --no-reread "$IMG"

LOOP="$(losetup --show -fP "$IMG")"
e2fsck -fp "${LOOP}p1" >/dev/null || [ $? -le 1 ]
resize2fs "${LOOP}p1" >/dev/null
mkdir -p "$MNT"
mount "${LOOP}p1" "$MNT"
pre_boot_kb="$(df --output=size -k "$MNT" | tail -n1)"
ROOT_UUID="$(blkid -s UUID -o value "${LOOP}p1")"
IMAGE_HOSTKEY="$(cat "${MNT}/etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null || true)"
for m in dev dev/pts proc sys; do mount --bind "/${m}" "${MNT}/${m}"; done
mount -t tmpfs tmpfs "${MNT}/run"
cp /etc/resolv.conf "${WORK}/resolv.conf"

# Debian's arm64 kernel of the image's release, unpacked (not installed: dpkg never sees it, so
# the upgrade round below only touches the image's own packages)
KDIR="${MNT}/tmp/sim-kernel"
mkdir -p "$KDIR"
in_chroot() { chroot "$MNT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root "$@"; }
resolv_backup="$(readlink "${MNT}/etc/resolv.conf" || true)"
cp --remove-destination "${WORK}/resolv.conf" "${MNT}/etc/resolv.conf"
in_chroot apt-get update -qq
kpkg="$(in_chroot apt-cache depends linux-image-arm64 | awk '/Depends: linux-image-[0-9]/ { print $2; exit }')"
[ -n "$kpkg" ] || { echo "cannot resolve Debian's linux-image-arm64"; exit 1; }
in_chroot sh -c "cd /tmp/sim-kernel && apt-get download -qq ${kpkg}"
KVER="${kpkg#linux-image-}"
KVER="${KVER%-unsigned}"
# Unpacked aside, then only the modules copied in: extracting into the merged-/usr root could
# replace its /lib symlink with a directory
dpkg-deb -x "$KDIR"/linux-image-*.deb "${WORK}/kpkg"
kmods="${WORK}/kpkg/usr/lib/modules/${KVER}"
[ -d "$kmods" ] || kmods="${WORK}/kpkg/lib/modules/${KVER}"
cp -a "$kmods" "${MNT}/usr/lib/modules/"
cp "${WORK}/kpkg/boot/vmlinuz-${KVER}" "${WORK}/vmlinuz"
in_chroot depmod "$KVER"
if [ -n "${SIM_UWE5622_SRC:-}" ]; then
  # The same driver commit as the board image, built against the simulation kernel's headers
  # (Debian's, in a container of the image's release) and installed the way the image has it
  release="$(sed -n 's/^VERSION_CODENAME=//p' "${MNT}/usr/lib/os-release")"
  mkdir -p "${WORK}/uwe5622"
  docker run --rm -v "$(cd "$SIM_UWE5622_SRC" && pwd):/src:ro" -v "${HERE}/../uwe5622:/tools:ro" \
    -v "${WORK}/uwe5622:/out" "debian:${release}" bash -euc \
    "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
       linux-headers-${KVER} make gcc binutils kmod >/dev/null && /tools/build-modules.sh /src /usr/src/linux-headers-${KVER} /out"
  install -d -m 755 "${MNT}/usr/lib/modules/${KVER}/updates/uwe5622"
  install -m 644 "${WORK}/uwe5622/"*.ko "${MNT}/usr/lib/modules/${KVER}/updates/uwe5622/"
  in_chroot depmod "$KVER"
  echo "# uwe5622-mainline modules built for the simulation kernel ${KVER}"
fi
# MODULES=most: the virt machine's disk/net drivers must be in the initrd
cp -r "${MNT}/etc/initramfs-tools" "${MNT}/tmp/sim-initramfs-conf"
sed -i 's/^MODULES=.*/MODULES=most/' "${MNT}/tmp/sim-initramfs-conf/initramfs.conf"
in_chroot mkinitramfs -d /tmp/sim-initramfs-conf -o /tmp/sim-kernel/initrd.img "$KVER"
cp "${KDIR}/initrd.img" "${WORK}/initrd.img"
rm -rf "$KDIR" "${WORK}/kpkg" "${MNT}/tmp/sim-initramfs-conf"
rm -rf "${MNT}/var/lib/apt/lists/"*
if [ -n "$resolv_backup" ]; then ln -sf "$resolv_backup" "${MNT}/etc/resolv.conf"; fi
echo "# simulation kernel: Debian ${KVER}"

# The provisioning file, exactly as the README tells users to write it
ssh-keygen -q -t ed25519 -N '' -f "${WORK}/id_ed25519"
cat > "${MNT}/boot/opi-provision.env" <<EOF
OPI_SSH_USER=${USER_NAME}
OPI_SSH_PASSWORD="${PASSWORD}"
OPI_SSH_AUTHORIZED_KEYS=$(cat "${WORK}/id_ed25519.pub")
OPI_HOSTNAME=opi-sim
OPI_TIMEZONE=Asia/Jakarta
EOF
chmod 600 "${MNT}/boot/opi-provision.env"
unmount_image

# --- VM ---
SSH_OPTS=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10 -o ServerAliveInterval=15)
vm()      { ssh "${SSH_OPTS[@]}" -o BatchMode=yes -i "${WORK}/id_ed25519" "${USER_NAME}@127.0.0.1" "$@"; }
vm_sudo() { printf '%s\n' "$PASSWORD" | vm "sudo -S -p '' $*"; }

# SSH is restarted during first boot (host keys, provisioning), which kills a single
# `systemctl is-system-running --wait`: ask again until systemd says it is done
settle_vm() {  # timeout seconds
  local start=$SECONDS state
  while [ $((SECONDS - start)) -lt "$1" ]; do
    state="$(vm "systemctl is-system-running" 2>/dev/null || true)"
    case "$state" in running|degraded) return 0 ;; esac
    sleep 5
  done
  echo "# system did not settle within $1 s (state: ${state:-unreachable})"
}

boot_vm() {  # name
  local cpu=(-cpu cortex-a53) accel=(-accel "tcg,thread=multi")
  [ "$ACCEL" = kvm ] && { cpu=(-cpu host); accel=(-accel kvm); }
  qemu-system-aarch64 -machine virt "${cpu[@]}" "${accel[@]}" -smp "$CPUS" -m "$MEMORY" \
    -kernel "${WORK}/vmlinuz" -initrd "${WORK}/initrd.img" \
    -append "root=UUID=${ROOT_UUID} rootwait rw console=ttyAMA0 panic=10" \
    -drive "if=virtio,format=raw,file=${IMG}" \
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${PORT}-:22" \
    -device virtio-net-pci,netdev=net0,romfile= \
    -device virtio-rng-pci -display none -serial "file:${WORK}/console-$1.log" \
    -daemonize -pidfile "${WORK}/qemu.pid"
  local start=$SECONDS
  until vm true 2>/dev/null; do
    if [ $((SECONDS - start)) -gt 1500 ]; then fail "boot ($1): SSH up within 25 min"; exit 1; fi
    sleep 10
  done
  ok "boot ($1): SSH up after $((SECONDS - start)) s"
  # Let first-boot units settle (running or degraded both end the wait)
  settle_vm 900
}

reboot_vm() {  # name
  vm_sudo "systemctl reboot" || true
  sleep 20
  # QEMU keeps running across the guest reboot
  local start=$SECONDS
  until vm true 2>/dev/null; do
    if [ $((SECONDS - start)) -gt 1500 ]; then fail "reboot ($1): SSH back within 25 min"; exit 1; fi
    sleep 10
  done
  ok "reboot ($1): SSH back after $((SECONDS - start)) s"
  settle_vm 600
}

# Measurements for metrics.json (SIM_METRICS_FILE): key=value lines go there, the rest to the log
measure() {  # sim-metrics.sh arguments...
  scp -q -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    -i "${WORK}/id_ed25519" "${HERE}/sim-metrics.sh" "${USER_NAME}@127.0.0.1:/tmp/sim-metrics.sh"
  local out
  out="$(vm_sudo "bash /tmp/sim-metrics.sh $*" 2>&1)" || echo "# measurement '$*' failed"
  printf '%s\n' "$out" | grep -v '^[a-z0-9_]*=' || true
  printf '%s\n' "$out" | grep '^[a-z0-9_]*=' | sed 's/^/# metric /' || true
  if [ -n "${SIM_METRICS_FILE:-}" ]; then printf '%s\n' "$out" | grep '^[a-z0-9_]*=' >> "$SIM_METRICS_FILE" || true; fi
}

expect() {  # description command...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi
}

checks() {  # round
  local r="$1" avail
  echo "# --- checks (${r}) ---"
  if vm_sudo /usr/local/sbin/opi-selfcheck; then ok "opi-selfcheck (${r})"; else fail "opi-selfcheck (${r})"; fi
  expect "password login from the LAN (${r})" sshpass -p "$PASSWORD" ssh "${SSH_OPTS[@]}" \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no "${USER_NAME}@127.0.0.1" true
  expect "root login refused (${r})" bash -c "! ssh ${SSH_OPTS[*]} -o BatchMode=yes -i '${WORK}/id_ed25519' root@127.0.0.1 true"
  expect "sudo needs the password (${r})" bash -c "! ssh ${SSH_OPTS[*]} -o BatchMode=yes -i '${WORK}/id_ed25519' ${USER_NAME}@127.0.0.1 'sudo -n true'"
  expect "user not in the docker group (${r})" bash -c "! ssh ${SSH_OPTS[*]} -o BatchMode=yes -i '${WORK}/id_ed25519' ${USER_NAME}@127.0.0.1 'id -nG' | grep -qw docker"
  expect "docker runs a container (${r})" vm_sudo docker run --rm hello-world
  expect "container has no-new-privileges (${r})" vm_sudo "docker run --rm alpine:3 grep -q '^NoNewPrivs:[[:space:]]*1' /proc/self/status"
  expect "dozzle answers (${r})" vm "curl -fsS -o /dev/null -m 10 http://127.0.0.1:27461/"
  vm "systemctl --failed --no-legend --plain" | sed 's/^/# failed unit: /' || true
  avail="$(vm "awk '/MemAvailable/ { print int(\$2 / 1024) }' /proc/meminfo")"
  echo "# memory (${r}): ${avail} MiB available of ${MEMORY} MiB"
  [ "${avail:-0}" -ge "$MIN_AVAIL" ] && ok "memory available >= ${MIN_AVAIL} MiB (${r})" \
    || fail "memory available >= ${MIN_AVAIL} MiB (${r}: ${avail})"
}

# The uwe5622-mainline driver with no UWE5622 present: what the board's driver does when the chip
# doesn't answer. Proves the integration (modprobe finds updates/, dependencies, blacklist) and
# robustness (probe fails cleanly, unload frees everything, no oops/WARN/BUG), not Wi-Fi itself.
uwe5622_rounds() {
  local rounds="${SIM_UWE5622_ROUNDS:-10}" i loaded=0 unloaded=0 before taint0 taint1 bad
  local mods='uwe5622_bsp_sdio|sprdwl_ng|sprdbt_tty'
  echo "# --- uwe5622-mainline without hardware: ${rounds} load/unload rounds ---"
  if vm_sudo "modinfo -n sprdwl_ng" 2>/dev/null | grep -q '/updates/uwe5622/sprdwl_ng\.ko$'; then
    ok "modprobe finds sprdwl_ng in updates/uwe5622"
  else
    fail "modprobe finds sprdwl_ng in updates/uwe5622"
  fi
  before="$(vm_sudo "dmesg" | wc -l)"
  taint0="$(vm "cat /proc/sys/kernel/tainted")"
  for i in $(seq 1 "$rounds"); do
    # sprdbt_tty is blacklisted with "install ... /bin/true"; --ignore-install loads it anyway
    vm_sudo "timeout 300 sh -c 'modprobe sprdwl_ng; modprobe --ignore-install sprdbt_tty'" \
      >> "${WORK}/uwe5622-rounds.log" 2>&1 || echo "# round ${i}: load returned an error" >> "${WORK}/uwe5622-rounds.log"
    [ "$(vm "lsmod" | grep -cE "^(${mods}) ")" -eq 3 ] && loaded=$((loaded + 1))
    vm_sudo "timeout 300 sh -c 'rmmod sprdbt_tty; rmmod sprdwl_ng; rmmod uwe5622_bsp_sdio'" \
      >> "${WORK}/uwe5622-rounds.log" 2>&1 || echo "# round ${i}: unload returned an error" >> "${WORK}/uwe5622-rounds.log"
    [ "$(vm "lsmod" | grep -cE "^(${mods}) ")" -eq 0 ] && unloaded=$((unloaded + 1))
  done
  [ "$loaded" -eq "$rounds" ] && ok "all three modules load without hardware (${loaded}/${rounds})" \
    || { fail "all three modules load without hardware (${loaded}/${rounds})"; tail -n 40 "${WORK}/uwe5622-rounds.log"; }
  [ "$unloaded" -eq "$rounds" ] && ok "all three modules unload (${unloaded}/${rounds})" \
    || { fail "all three modules unload (${unloaded}/${rounds})"; tail -n 40 "${WORK}/uwe5622-rounds.log"; }
  vm_sudo "dmesg" | tail -n +"$((before + 1))" > "${WORK}/uwe5622-dmesg.log" || true
  echo "# kernel log of the rounds ($(wc -l < "${WORK}/uwe5622-dmesg.log") lines), first round:"
  head -n 40 "${WORK}/uwe5622-dmesg.log" | sed 's/^/#   /'
  bad="$(grep -E 'Oops|BUG:|WARNING:|Call trace:|Unable to handle|Kernel panic|refcount_t:|list_(add|del) corruption|use-after-free|soft lockup|hung_task|blocked for more than' \
         "${WORK}/uwe5622-dmesg.log" || true)"
  [ -z "$bad" ] && ok "no oops, WARN or BUG in the kernel log" \
    || { fail "no oops, WARN or BUG in the kernel log"; grep -B 5 -A 30 -m 3 -E 'Oops|BUG:|WARNING:|Call trace:' "${WORK}/uwe5622-dmesg.log" | sed 's/^/#   /'; }
  # Taint flags new since the rounds: D (died, 128), W (warning, 512), B (bad page, 32),
  # L (soft lockup, 16384). O and E (out-of-tree, unsigned module) are expected.
  taint1="$(vm "cat /proc/sys/kernel/tainted")"
  [ $(( (taint1 & ~taint0) & (128 | 512 | 32 | 16384) )) -eq 0 ] && ok "kernel not tainted by a crash or warning (${taint0} -> ${taint1})" \
    || fail "kernel not tainted by a crash or warning (${taint0} -> ${taint1})"
  vm_sudo "modprobe sprdbt_tty" >/dev/null 2>&1 || true
  if vm "lsmod" | grep -q '^sprdbt_tty '; then fail "Bluetooth blacklist still applies (modprobe sprdbt_tty is a no-op)"; else ok "Bluetooth blacklist still applies (modprobe sprdbt_tty is a no-op)"; fi
}

boot_vm first

echo "# --- first boot ---"
expect "provisioning file shredded" vm_sudo test ! -e /boot/opi-provision.env
expect "provisioning recorded" vm_sudo test -s /var/lib/opi-provision/provisioned
expect "host name from the file" bash -c "[ \"\$(ssh ${SSH_OPTS[*]} -o BatchMode=yes -i '${WORK}/id_ed25519' ${USER_NAME}@127.0.0.1 hostname)\" = opi-sim ]"
expect "time zone from the file" bash -c "ssh ${SSH_OPTS[*]} -o BatchMode=yes -i '${WORK}/id_ed25519' ${USER_NAME}@127.0.0.1 'readlink /etc/localtime' | grep -q Asia/Jakarta"
new_hostkey="$(vm cat /etc/ssh/ssh_host_ed25519_key.pub)"
[ -n "$new_hostkey" ] && [ "$new_hostkey" != "$IMAGE_HOSTKEY" ] && ok "SSH host keys regenerated on first boot" \
  || fail "SSH host keys regenerated on first boot"
root_kb="$(vm "df --output=size -k / | tail -n1")"
[ "$root_kb" -gt "$((pre_boot_kb + 2097152))" ] && ok "root filesystem grown to the card" \
  || fail "root filesystem grown to the card (${pre_boot_kb} -> ${root_kb} KiB)"

[ -n "${SIM_SKIP_MEASURE:-}" ] || measure mem first_boot   # Docker up, no container yet

# A real deployment from this repo, the way the Orange Pi workflow runs it (root via sudo)
scp -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -i "${WORK}/id_ed25519" "${REPO}/bash-scripts/init-dozzle.sh" "${USER_NAME}@127.0.0.1:/tmp/init-dozzle.sh"
if vm_sudo "env DOZZLE_PASSWORD='${DOZZLE_PASSWORD}' bash /tmp/init-dozzle.sh" > "${WORK}/dozzle.log" 2>&1; then
  ok "bash-scripts/init-dozzle.sh deploys"
else
  fail "bash-scripts/init-dozzle.sh deploys"; tail -n 40 "${WORK}/dozzle.log"
fi

checks "first boot"
[ -n "${SIM_SKIP_MEASURE:-}" ] || measure mem docker   # Docker + Dozzle up

if [ -z "${SIM_SKIP_MEASURE:-}" ]; then
  # A normal boot of the provisioned board (no first-boot work), then idle with Dozzle running:
  # what the board does all day. TCG is slower than the board, so compare runs, not absolutes.
  echo "# --- measurements: plain reboot, then idle ---"
  reboot_vm measure
  measure boot
  sleep "${SIM_SETTLE_S:-120}"
  measure mem idle
  measure idle "${SIM_IDLE_S:-60}"
  measure disk "${SIM_DISK_S:-300}"
fi

if [ -n "${SIM_UWE5622_SRC:-}" ]; then
  uwe5622_rounds
  checks "after the uwe5622 rounds"
fi

if [ -z "${SIM_SKIP_UPGRADE:-}" ]; then
  echo "# --- upstream updates ---"
  # The daily security update, for real (whatever trixie-security has beyond the image)
  if vm_sudo "systemctl start opi-security-upgrade.service" > "${WORK}/security.log" 2>&1; then
    ok "security upgrade (opi-security-upgrade.service)"
  else
    fail "security upgrade (opi-security-upgrade.service)"; cat "${WORK}/security.log"
  fi
  vm_sudo "journalctl -u opi-security-upgrade.service -o cat --no-pager" 2>/dev/null \
    | grep -E '^(Inst|Setting up|[0-9]+ upgraded)' | head -n 30 | sed 's/^/# /' || true
  if vm_sudo "journalctl -u opi-security-upgrade.service -o cat --no-pager" 2>/dev/null | grep -qi 'conffile'; then
    fail "security upgrade not stopped by a conffile"
  else
    ok "security upgrade not stopped by a conffile"
  fi
  # Everything apt offers now (Debian, Armbian, Docker repos), then a reinstall of each package
  # that owns files next to ours, as a stand-in for future upgrades of exactly those packages
  APT_ARGS="-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
  if vm_sudo "env DEBIAN_FRONTEND=noninteractive sh -c 'apt-get update -q && apt-get ${APT_ARGS} dist-upgrade && apt-get ${APT_ARGS} install --reinstall openssh-server openssh-client nftables docker-ce docker-ce-cli containerd.io systemd sudo'" \
       > "${WORK}/upgrade.log" 2>&1; then
    ok "apt upgrade + reinstall without prompts or errors"
  else
    fail "apt upgrade + reinstall without prompts or errors"; tail -n 60 "${WORK}/upgrade.log"
  fi
  grep -E '^(Inst|Setting up|Unpacking) ' "${WORK}/upgrade.log" | head -n 50 | sed 's/^/# /' || true
  if vm_sudo "opi-security-upgrade --dry-run" > "${WORK}/security-dry.log" 2>&1; then
    ok "security upgrade dry run after the full upgrade"
  else
    fail "security upgrade dry run after the full upgrade"; tail -n 30 "${WORK}/security-dry.log"
  fi

  reboot_vm "after upgrade"
  checks "after upgrade + reboot"
fi

stop_vm
[ "$FAILED" -eq 0 ] && echo "# simulation: all passed" || echo "# simulation: FAILED"
exit "$FAILED"

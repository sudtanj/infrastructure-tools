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

set -euo pipefail

IMG_IN="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
MEMORY="${SIM_MEMORY:-1024}"
CPUS="${SIM_CPUS:-4}"
ACCEL="${SIM_ACCEL:-tcg}"
MIN_AVAIL="${SIM_MIN_AVAILABLE_MB:-400}"
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
  vm "timeout 900 systemctl is-system-running --wait" || true
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

# A real deployment from this repo, the way the Orange Pi workflow runs it (root via sudo)
scp -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
  -i "${WORK}/id_ed25519" "${REPO}/bash-scripts/init-dozzle.sh" "${USER_NAME}@127.0.0.1:/tmp/init-dozzle.sh"
if vm_sudo "env DOZZLE_PASSWORD='${DOZZLE_PASSWORD}' bash /tmp/init-dozzle.sh" > "${WORK}/dozzle.log" 2>&1; then
  ok "bash-scripts/init-dozzle.sh deploys"
else
  fail "bash-scripts/init-dozzle.sh deploys"; tail -n 40 "${WORK}/dozzle.log"
fi

checks "first boot"

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

  vm_sudo "systemctl reboot" || true
  sleep 20
  # QEMU keeps running across the guest reboot
  boot_vm_wait_start=$SECONDS
  until vm true 2>/dev/null; do
    if [ $((SECONDS - boot_vm_wait_start)) -gt 1500 ]; then fail "reboot: SSH back within 25 min"; exit 1; fi
    sleep 10
  done
  ok "reboot: SSH back after $((SECONDS - boot_vm_wait_start)) s"
  vm "timeout 600 systemctl is-system-running --wait" || true
  checks "after upgrade + reboot"
fi

stop_vm
[ "$FAILED" -eq 0 ] && echo "# simulation: all passed" || echo "# simulation: FAILED"
exit "$FAILED"

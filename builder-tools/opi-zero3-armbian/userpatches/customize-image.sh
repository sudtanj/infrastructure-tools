#!/bin/bash
# Armbian customization hook: runs inside the image chroot, with userpatches/overlay/ mounted
# read-only at /tmp/overlay. Turns the minimal CLI image into a locked-down Docker host:
# Docker CE (engine only), host firewall, hardened sshd/sysctl, no default login, first-boot
# provisioning from /boot/opi-provision.env. See ../README.md.
#
# arguments: $RELEASE $LINUXFAMILY $BOARD $BUILD_DESKTOP

set -euo pipefail

RELEASE=$1
OVERLAY=/tmp/overlay
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

echo "[customize] size: no docs, man pages, translations or translated package lists"
# First, so the packages installed below are filtered too; stays for every later upgrade
install -D -m 644 "${OVERLAY}/dpkg-nodoc.conf" /etc/dpkg/dpkg.cfg.d/90opi-nodoc
install -D -m 644 "${OVERLAY}/apt-lists.conf" /etc/apt/apt.conf.d/50opi-lists
# The same paths for the packages already installed
find /usr/share/doc -mindepth 1 ! -type d ! -name copyright -delete
find /usr/share/doc -mindepth 1 -depth -type d -empty -delete
find /usr/share/man /usr/share/info /usr/share/groff /usr/share/lintian -mindepth 1 -delete 2>/dev/null || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name locale.alias -exec rm -rf {} +
# Armbian fetched the lists uncompressed; the update below fetches them again, compressed
rm -rf /var/lib/apt/lists/*

echo "[customize] size: no firmware for hardware this board can't have"
install -D -m 644 "${OVERLAY}/dpkg-firmware.conf" /etc/dpkg/dpkg.cfg.d/91opi-firmware
fw=/usr/lib/firmware
rm -rf "${fw}/qcom" "${fw}/ath11k" "${fw}/ath12k" "${fw}/rkwifi" "${fw}"/adsp.* "${fw}"/iwlwifi-*
# The board's own Wi-Fi must survive the filter
ls "${fw}"/uwe5622/* >/dev/null

echo "[customize] Docker CE for Debian ${RELEASE}"
"${APT[@]}" update
"${APT[@]}" install --no-install-recommends ca-certificates curl gnupg
install -d -m 755 /etc/apt/keyrings
curl -fsSL --retry 3 https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod 644 /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${RELEASE} stable" \
  > /etc/apt/sources.list.d/docker.list
"${APT[@]}" update
# Engine only: no compose/buildx plugins, no rootless extras (nothing here uses them)
"${APT[@]}" install --no-install-recommends docker-ce docker-ce-cli containerd.io iptables \
  nftables unattended-upgrades

echo "[customize] removing packages a Docker host doesn't need"
purge=()
# Armbian's minimal list is a general-purpose CLI; kept on purpose: rsync (armbian-ramlog),
# u-boot-tools/initramfs-tools (kernel upgrades), parted/fdisk (first-boot resize), iw/wpasupplicant
for p in rsyslog alsa-utils man-db pahole debsums avahi-daemon avahi-autoipd bluetooth bluez bluez-tools \
         cups-daemon modemmanager network-manager rpcbind nfs-common samba-common-bin telnet \
         btrfs-progs dosfstools figlet toilet wireguard-tools; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q '^install ok installed' && purge+=("$p")
done
if [ "${#purge[@]}" -gt 0 ]; then
  # Fail rather than let a purge take a package that depends on these (e.g. armbian-bsp-cli)
  extra="$(apt-get -s purge "${purge[@]}" | awk '/^Purg /{ print $2 }' \
           | grep -vxF -f <(printf '%s\n' "${purge[@]}") || true)"
  [ -z "$extra" ] || { echo "[customize] purge would also remove: ${extra//$'\n'/ }" >&2; exit 1; }
  "${APT[@]}" purge "${purge[@]}"
fi
"${APT[@]}" clean

echo "[customize] config files"
install -D -m 644 "${OVERLAY}/docker-daemon.json" /etc/docker/daemon.json
# Only new files and drop-ins: no package-owned file is edited, so apt/unattended upgrades never
# stop on a conffile prompt or overwrite the lockdown (opi-selfcheck asserts this)
install -D -m 644 "${OVERLAY}/sshd-hardening.conf" /etc/ssh/sshd_config.d/00-opi-hardening.conf
# Armbian edits sshd_config (PermitRootLogin yes). Our drop-in wins anyway, but the package's own
# file lets openssh-server upgrades replace it without asking
cp /usr/share/openssh/sshd_config /etc/ssh/sshd_config
install -D -m 644 "${OVERLAY}/nftables.conf" /etc/opi/nftables.conf
install -D -m 644 "${OVERLAY}/opi-firewall.service" /etc/systemd/system/opi-firewall.service
install -D -m 644 "${OVERLAY}/sysctl-hardening.conf" /etc/sysctl.d/90-opi-hardening.conf
install -D -m 644 "${OVERLAY}/modprobe-blacklist.conf" /etc/modprobe.d/opi-blacklist.conf
install -D -m 644 "${OVERLAY}/journald.conf" /etc/systemd/journald.conf.d/90-opi.conf
install -D -m 644 "${OVERLAY}/unattended-upgrades.conf" /etc/apt/apt.conf.d/52opi-unattended-upgrades
install -D -m 644 "${OVERLAY}/auto-upgrades.conf" /etc/apt/apt.conf.d/99opi-auto-upgrades
install -D -m 755 "${OVERLAY}/opi-provision" /usr/local/sbin/opi-provision
install -D -m 755 "${OVERLAY}/opi-selfcheck" /usr/local/sbin/opi-selfcheck
install -D -m 644 "${OVERLAY}/opi-provision.service" /etc/systemd/system/opi-provision.service
install -D -m 755 "${OVERLAY}/opi-init-tailscale-docker.sh" /usr/local/lib/opi-image/opi-init-tailscale-docker.sh

echo "[customize] services"
systemctl enable docker.service containerd.service opi-firewall.service opi-provision.service \
  unattended-upgrades.service
# aw859a-bluetooth (Armbian's uwe5622 extension) would fail every boot without bluez
systemctl mask bluetooth.service aw859a-bluetooth.service ModemManager.service avahi-daemon.service \
  2>/dev/null || true

echo "[customize] no default login"
# Armbian sets a known root password, autologin on the consoles and an interactive first-login
# wizard. The only login is the user opi-provision creates.
passwd -l root
rm -f /root/.not_logged_in_yet
rm -f /etc/systemd/system/getty@.service.d/override.conf \
      /etc/systemd/system/serial-getty@.service.d/override.conf
rmdir /etc/systemd/system/getty@.service.d /etc/systemd/system/serial-getty@.service.d 2>/dev/null || true

# Fails the build when an upstream Armbian/Debian/Docker change undid part of the lockdown
echo "[customize] self-check"
/usr/local/sbin/opi-selfcheck --image
echo "[customize] done"

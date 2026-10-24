#!/usr/bin/env bats
# The overlay config files against the real packages of the image's Debian release (see run.sh).

SRC=/src/userpatches/overlay

refute() { if "$@"; then echo "unexpectedly succeeded: $*" >&2; return 1; fi; }

sshd_value() {  # address key
  sshd -T -C "user=opi,host=probe,addr=$1" | awk -v k="$2" '$1 == k { print $2; exit }'
}

setup_file() {
  install -D -m 644 "${SRC}/sshd-hardening.conf" /etc/ssh/sshd_config.d/00-opi-hardening.conf
  # Written by opi-provision after ours; must stay global, not inside our Match block
  printf 'AllowUsers opi\n' > /etc/ssh/sshd_config.d/10-opi-users.conf
}

@test "sshd: config valid and the package's sshd_config untouched" {
  sshd -t
  refute grep -q opi /etc/ssh/sshd_config
}

@test "sshd: passwords from LAN and tailnet only" {
  [ "$(sshd_value 192.168.1.10 passwordauthentication)" = yes ]
  [ "$(sshd_value 10.1.2.3 passwordauthentication)" = yes ]
  [ "$(sshd_value 172.20.0.5 passwordauthentication)" = yes ]
  [ "$(sshd_value 100.100.10.10 passwordauthentication)" = yes ]
  [ "$(sshd_value fd00::5 passwordauthentication)" = yes ]
  [ "$(sshd_value fe80::1 passwordauthentication)" = yes ]
  [ "$(sshd_value 203.0.113.9 passwordauthentication)" = no ]
  [ "$(sshd_value 8.8.8.8 passwordauthentication)" = no ]
  [ "$(sshd_value 2001:db8::9 passwordauthentication)" = no ]
  [ "$(sshd_value 172.32.0.1 passwordauthentication)" = no ]
}

@test "sshd: the rest is locked from everywhere" {
  for addr in 203.0.113.9 192.168.1.10; do
    [ "$(sshd_value "$addr" permitrootlogin)" = no ]
    [ "$(sshd_value "$addr" allowtcpforwarding)" = no ]
    [ "$(sshd_value "$addr" allowagentforwarding)" = no ]
    [ "$(sshd_value "$addr" x11forwarding)" = no ]
    [ "$(sshd_value "$addr" permittunnel)" = no ]
    [ "$(sshd_value "$addr" maxauthtries)" = 3 ]
    [ "$(sshd_value "$addr" kbdinteractiveauthentication)" = no ]
  done
}

@test "sshd: our Match block doesn't swallow later drop-ins" {
  [ "$(sshd_value 203.0.113.9 allowusers)" = opi ]
  [ "$(sshd_value 192.168.1.10 allowusers)" = opi ]
}

@test "nftables: ruleset valid, reload idempotent, other tables kept" {
  nft -c -f "${SRC}/nftables.conf"
  # Stand-ins for Docker's and Tailscale's tables
  nft add table ip filter
  nft add chain ip filter DOCKER
  nft add table inet ts-filter
  nft -f "${SRC}/nftables.conf"
  nft -f "${SRC}/nftables.conf"
  [ "$(nft list tables | grep -c 'inet opi_host')" -eq 1 ]
  nft list chain ip filter DOCKER
  nft list table inet ts-filter
  nft list chain inet opi_host input | grep -q 'policy drop'
}

@test "docker daemon.json is valid JSON with the expected settings" {
  python3 - "${SRC}/docker-daemon.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["log-driver"] == "local"
assert d["no-new-privileges"] is True
assert d["live-restore"] is True
EOF
}

@test "sysctl: well-formed lines" {
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^-?[a-z0-9_.]+\ =\ [0-9]+$ ]] || { echo "bad line: $line"; return 1; }
  done < "${SRC}/sysctl-hardening.conf"
}

@test "security upgrade: only <release>-security, from its own index; system lists untouched" {
  install -D -m 755 "${SRC}/opi-security-upgrade" /usr/local/sbin/opi-security-upgrade
  before="$(ls -l /var/lib/apt/lists)"
  run /usr/local/sbin/opi-security-upgrade --dry-run
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(ls -l /var/lib/apt/lists)" = "$before" ]
  . /etc/os-release
  cat /var/lib/opi-security-upgrade/sources.list
  [ "$(wc -l < /var/lib/opi-security-upgrade/sources.list)" -eq 1 ]
  grep -qxE "deb \[signed-by=/usr/share/keyrings/debian-archive-keyring\.(pgp|gpg)\] http://deb\.debian\.org/debian-security ${VERSION_CODENAME}-security main contrib non-free non-free-firmware" \
    /var/lib/opi-security-upgrade/sources.list
  compgen -G "/var/lib/opi-security-upgrade/lists/*_${VERSION_CODENAME}-security_*Packages*"
  # Whatever it would install comes from the security archive
  inst="$(grep '^Inst ' <<< "$output" || true)"
  refute grep -v -e 'Debian-Security' -e '^$' <<< "$inst"
  # For real: upgrades whatever the container's Debian is missing, without prompts
  run /usr/local/sbin/opi-security-upgrade
  echo "$output"
  [ "$status" -eq 0 ]
  run /usr/local/sbin/opi-security-upgrade --dry-run
  grep -q "^0 upgraded" <<< "$output"
}

@test "unit files have the sections systemd needs" {
  for u in opi-firewall.service opi-provision.service; do
    grep -q '^\[Service\]' "${SRC}/${u}"
    grep -q '^ExecStart=/' "${SRC}/${u}"
    grep -q '^WantedBy=' "${SRC}/${u}"
  done
  # Started by its timer only
  grep -q '^ExecStart=/usr/local/sbin/opi-security-upgrade$' "${SRC}/opi-security-upgrade.service"
  refute grep -q '^\[Install\]' "${SRC}/opi-security-upgrade.service"
  grep -q '^OnCalendar=' "${SRC}/opi-security-upgrade.timer"
  grep -q '^Persistent=true' "${SRC}/opi-security-upgrade.timer"
  grep -q '^WantedBy=timers.target' "${SRC}/opi-security-upgrade.timer"
}

@test "dpkg: no docs, man pages or translations on install/upgrade, licenses kept" {
  install -D -m 644 "${SRC}/dpkg-nodoc.conf" /etc/dpkg/dpkg.cfg.d/90opi-nodoc
  apt-get install -y -qq --no-install-recommends wget >/dev/null  # not in the base image: a fresh install
  rm -f /etc/dpkg/dpkg.cfg.d/90opi-nodoc
  [ -s /usr/share/doc/wget/copyright ]
  # what the package ships (dpkg -L may list filtered paths too, so ask the .deb)
  (cd "$BATS_TEST_TMPDIR" && apt-get download -qq wget 2>/dev/null)
  shipped="$(dpkg-deb -c "$BATS_TEST_TMPDIR"/wget_*.deb | awk '{ print $6 }' | sed 's|^\.||' \
             | grep -E '^/usr/share/(man|locale)/.+\.(gz|mo)$')"
  [ -n "$shipped" ]
  for f in $shipped; do
    [ ! -e "$f" ] || { echo "installed: $f" >&2; return 1; }
  done
  [ -x /usr/bin/wget ]
}

@test "apt: package lists stay compressed, no translations" {
  # The Debian container image ships the same settings; drop them so only ours is tested
  rm -f /etc/apt/apt.conf.d/docker-*
  install -D -m 644 "${SRC}/apt-lists.conf" /etc/apt/apt.conf.d/50opi-lists
  apt-config dump | grep -E '^Acquire::(Languages|GzipIndexes)'
  apt-config dump | grep -qE '^Acquire::Languages(::)? "none";'
  rm -rf /var/lib/apt/lists/*
  apt-get update -qq
  ls /var/lib/apt/lists/
  compgen -G "/var/lib/apt/lists/*_Packages.*" >/dev/null
  refute compgen -G '/var/lib/apt/lists/*_Packages'
  refute compgen -G '/var/lib/apt/lists/*Translation*'
  apt-cache policy tar | grep -q Candidate
}

@test "dpkg: firmware for other hardware is skipped, the board's Wi-Fi and USB dongles' kept" {
  install -D -m 644 "${SRC}/dpkg-firmware.conf" /etc/dpkg/dpkg.cfg.d/91opi-firmware
  pkg="${BATS_TEST_TMPDIR}/fw"
  for f in qcom/sm8550/a.mbn adsp.b41 ath11k/x.bin ath12k/x.bin iwlwifi-8265-36.ucode rkwifi/fw.bin \
           uwe5622/wcnmodem.bin mediatek/mt7601u.bin rtl_bt/rtl8761bu_fw.bin ath10k/QCA9377/fw.bin \
           regulatory.db; do
    install -D /dev/null "${pkg}/lib/firmware/${f}"
  done
  mkdir -p "${pkg}/DEBIAN"
  printf 'Package: opi-fake-firmware\nVersion: 1\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' \
    > "${pkg}/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$pkg" "${BATS_TEST_TMPDIR}/fw.deb" >/dev/null
  dpkg -i "${BATS_TEST_TMPDIR}/fw.deb" >/dev/null
  rm -f /etc/dpkg/dpkg.cfg.d/91opi-firmware
  for f in qcom/sm8550/a.mbn adsp.b41 ath11k/x.bin ath12k/x.bin iwlwifi-8265-36.ucode rkwifi/fw.bin; do
    [ ! -e "/lib/firmware/${f}" ] || { echo "installed: $f" >&2; return 1; }
  done
  for f in uwe5622/wcnmodem.bin mediatek/mt7601u.bin rtl_bt/rtl8761bu_fw.bin ath10k/QCA9377/fw.bin regulatory.db; do
    [ -e "/lib/firmware/${f}" ] || { echo "missing: $f" >&2; return 1; }
  done
  dpkg -P opi-fake-firmware >/dev/null
}

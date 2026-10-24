#!/usr/bin/env bats
# opi-provision, run as root in a disposable Debian container (see run.sh). systemctl, netplan's
# generator, hostname, curl and the Tailscale script are stubs; useradd, chpasswd, sshd -t and the
# files under /etc are real.

bats_require_minimum_version 1.5.0

SRC=/src/userpatches/overlay
ENV_FILE=/boot/opi-provision.env
TS=/usr/local/lib/opi-image/opi-init-tailscale-docker.sh
# Credentials are generated per run, so no credential-looking literal is committed
rand() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20; }
PW="$(rand)"
PW2="$(rand)"
WIFI_PW="$(rand)"
TS_SECRET="$(rand)"

setup_file() {
  install -D -m 755 "${SRC}/opi-provision" /usr/local/sbin/opi-provision
  install -D -m 644 "${SRC}/sshd-hardening.conf" /etc/ssh/sshd_config.d/00-opi-hardening.conf
  install -D -m 755 /src/tests/unit/stubs/ts-script "$TS"
  install -D -m 755 /src/tests/unit/stubs/netplan-generate /usr/libexec/netplan/generate
  mkdir -p /boot
}

setup() {
  export PATH="/src/tests/unit/stubs:${PATH}"
  rm -f /tmp/stub-calls /tmp/ts-env /tmp/ts-rc /tmp/pwned /etc/netplan/20-opi-wifi.yaml
  userdel -r opi >/dev/null 2>&1 || true
}

provision() {
  printf '%s\n' "$@" > "$ENV_FILE"
  run --separate-stderr /usr/local/sbin/opi-provision
}

# bats runs tests under set -e, which ignores a failing "! cmd"; this fails the test instead
refute() { if "$@"; then echo "unexpectedly succeeded: $*" >&2; return 1; fi; }

password_is() {
  local hash
  hash="$(getent shadow "$1" | cut -d: -f2)"
  perl -e 'exit(crypt($ARGV[0], $ARGV[1]) eq $ARGV[1] ? 0 : 1)' "$2" "$hash"
}

@test "no provisioning file: nothing happens" {
  rm -f "$ENV_FILE"
  run /usr/local/sbin/opi-provision
  [ "$status" -eq 0 ]
  refute id opi
}

@test "creates the user with sudo, without docker, and locks everything else down" {
  groupadd -f docker
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}"
  [ "$status" -eq 0 ]
  password_is opi "$PW"
  id -nG opi | grep -qw sudo
  id -nG opi | grep -qw systemd-journal
  refute grep -qw docker <<< "$(id -nG opi)"
  [ "$(getent shadow root | cut -d: -f2 | cut -c1)" = '!' ] || [ "$(getent shadow root | cut -d: -f2 | cut -c1)" = '*' ]
  grep -qx 'AllowUsers opi' /etc/ssh/sshd_config.d/10-opi-users.conf
  [ ! -e "$ENV_FILE" ]
  [ -s /var/lib/opi-provision/provisioned ]
  grep -q 'systemctl reload-or-restart ssh' /tmp/stub-calls
}

@test "the file is parsed, never executed: quotes, CRLF, export, comments" {
  printf '%s\r\n' '# comment' '' "export OPI_SSH_USER='opi'" \
    'OPI_SSH_PASSWORD="$(touch /tmp/pwned)pw"' 'EVIL=$(touch /tmp/pwned)' > "$ENV_FILE"
  run /usr/local/sbin/opi-provision
  [ "$status" -eq 0 ]
  [ ! -e /tmp/pwned ]
  password_is opi '$(touch /tmp/pwned)pw'
  [[ "$output" == *"ignoring unknown key EVIL"* ]]
}

@test "secrets never reach the log" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}" "WIFI_SSID=home" "WIFI_PASSWORD=${WIFI_PW}" \
    "TAILSCALE_OAUTH_CLIENT_SECRET=${TS_SECRET}"
  [ "$status" -eq 0 ]
  [[ "$output$stderr" != *"$PW"* ]]
  [[ "$output$stderr" != *"$WIFI_PW"* ]]
  [[ "$output$stderr" != *"$TS_SECRET"* ]]
}

@test "invalid input is rejected and the file is kept for fixing" {
  for bad in "OPI_SSH_PASSWORD=${PW}" \
             "OPI_SSH_USER=root|OPI_SSH_PASSWORD=${PW}" \
             "OPI_SSH_USER=Bad User|OPI_SSH_PASSWORD=${PW}" \
             "OPI_SSH_USER=opi|OPI_SSH_PASSWORD=short" \
             "OPI_SSH_USER=opi|OPI_SSH_PASSWORD=${PW}:${PW2}" \
             "OPI_SSH_USER=opi|OPI_SSH_PASSWORD=${PW}|OPI_HOSTNAME=bad_host!"; do
    IFS='|' read -ra lines <<< "$bad"
    provision "${lines[@]}"
    [ "$status" -ne 0 ]
    [ -e "$ENV_FILE" ]
    refute id opi
  done
}

@test "authorized keys: several, separated by a literal \\n" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}" \
    'OPI_SSH_AUTHORIZED_KEYS=ssh-ed25519 AAAAone a@x\nssh-ed25519 AAAAtwo b@y'
  [ "$status" -eq 0 ]
  [ "$(wc -l < /home/opi/.ssh/authorized_keys)" -eq 2 ]
  grep -qx 'ssh-ed25519 AAAAtwo b@y' /home/opi/.ssh/authorized_keys
  [ "$(stat -c '%a %U' /home/opi/.ssh/authorized_keys)" = "600 opi" ]
  [ "$(stat -c '%a' /home/opi/.ssh)" = 700 ]
}

@test "host name and time zone" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}" "OPI_HOSTNAME=opi-test" "OPI_TIMEZONE=Asia/Jakarta"
  [ "$status" -eq 0 ]
  [ "$(cat /etc/hostname)" = opi-test ]
  grep -qP '^127\.0\.1\.1\topi-test$' /etc/hosts
  [ "$(grep -c '^127\.0\.1\.1' /etc/hosts)" -eq 1 ]
  [ "$(readlink /etc/localtime)" = /usr/share/zoneinfo/Asia/Jakarta ]
}

@test "unknown or path-traversing time zone is ignored" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}" "OPI_TIMEZONE=../../etc/passwd"
  [ "$status" -eq 0 ]
  [ "$(readlink /etc/localtime)" != /etc/passwd ]
}

@test "wi-fi: valid netplan YAML even with quotes and backslashes" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}" 'WIFI_SSID=my "home" \net' \
    'WIFI_PASSWORD=p"a\ss: #word' "WIFI_COUNTRY=ID"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' /etc/netplan/20-opi-wifi.yaml)" = 600 ]
  python3 - <<'EOF'
import yaml
w = yaml.safe_load(open("/etc/netplan/20-opi-wifi.yaml"))["network"]["wifis"]["wlan0"]
aps = w["access-points"]
assert list(aps) == ['my "home" \\net'], aps
assert aps['my "home" \\net']["password"] == 'p"a\\ss: #word'
assert w["regulatory-domain"] == "ID"
assert "match" not in w  # netplan's networkd backend rejects wifis with match rules
EOF
  grep -qx 'netplan-generate ' /tmp/stub-calls
  grep -qx 'systemctl restart netplan-wpa-wlan0.service' /tmp/stub-calls
}

@test "tailscale gets only its own variables" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}" "WIFI_PASSWORD=${WIFI_PW}" \
    "TAILSCALE_OAUTH_CLIENT_SECRET=${TS_SECRET}" "OPI_TS_TAGS=tag:opi" "OPI_TS_IP=100.100.10.10"
  [ "$status" -eq 0 ]
  grep -qx "TAILSCALE_OAUTH_CLIENT_SECRET=${TS_SECRET}" /tmp/ts-env
  grep -qx 'OPI_TS_TAGS=tag:opi' /tmp/ts-env
  grep -qx 'OPI_TS_IP=100.100.10.10' /tmp/ts-env
  refute grep -q 'PASSWORD' /tmp/ts-env
  refute grep -q '^OPI_SSH' /tmp/ts-env
  [ -s /var/lib/opi-provision/tailscale ]
}

@test "no secret: tailscale skipped" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}"
  [ "$status" -eq 0 ]
  [ ! -e /tmp/ts-env ]
}

@test "tailscale failure: unit fails, but the login exists and the file is gone" {
  echo 3 > /tmp/ts-rc
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}" "TAILSCALE_OAUTH_CLIENT_SECRET=${TS_SECRET}"
  [ "$status" -eq 3 ]
  password_is opi "$PW"
  [ ! -e "$ENV_FILE" ]
}

@test "running again updates the password" {
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW}"
  provision "OPI_SSH_USER=opi" "OPI_SSH_PASSWORD=${PW2}"
  [ "$status" -eq 0 ]
  password_is opi "$PW2"
}

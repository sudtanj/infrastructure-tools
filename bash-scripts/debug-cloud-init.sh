#!/bin/bash
# bash-scripts/debug-cloud-init.sh
# Read-only cloud-init diagnostics for a GCE VM (Container-Optimized OS or Ubuntu).
# CHANGES NOTHING. Safe to run any time, locally on the VM or through the workflow.
#
# Output uses the workflow's structured prefixes so every line survives its filter:
#   [*] info   [>] section   [+]/[✓] ok   [!] warning   [x] problem   [*]   | log excerpt
# It never prints the user-data contents. IPs, emails, tokens and URL credentials are masked
# before anything is printed.
#
# Env:  FULL=1    longer log excerpts (default: short)
#       STRICT=1  exit 1 when a problem is found (default: always exit 0)

set -uo pipefail

FULL="${FULL:-0}"
STRICT="${STRICT:-0}"
N_LOG=40; N_OUT=60
[ "$FULL" = "1" ] && { N_LOG=200; N_OUT=300; }

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo -n"
WARN=0; BAD=0
HINTS=()

# ---------- helpers ----------
# NOTE: when run as `bash -s`, this script itself arrives on stdin. Every external command below gets
# </dev/null so nothing can swallow the rest of the script.
info() { echo "[*] $*"; }
step() { echo "[>] $*"; }
okay() { echo "[✓] $*"; }
warn() { echo "[!] $*"; WARN=$((WARN + 1)); }
bad()  { echo "[x] $*"; BAD=$((BAD + 1)); }
hint() { HINTS+=("$*"); }
have() { command -v "$1" >/dev/null 2>&1; }
T()    { if have timeout; then timeout "${T_SECS:-20}" "$@"; else "$@"; fi; }
q()    { "$@" </dev/null 2>&1; }

san() {
  sed -E \
    -e 's#(://)[^/ @]+@#\1<creds>@#g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/<ip>/g' \
    -e 's/tskey-[A-Za-z0-9_-]+/tskey-<redacted>/g' \
    -e 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/<github-token>/g' \
    -e 's/sk-[A-Za-z0-9_-]{8,}/<api-key>/g' \
    -e 's/[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/<email>/g'
}
excerpt() { san | tail -n "${1:-30}" | sed 's/^/[*]   | /'; }

ERR_PAT='WARNING|ERROR|CRITICAL|Traceback|[Ff]ailed|[Uu]nable|not found|No such file|Permission denied|non-zero|exited with'

echo "[*] debug-cloud-init start"

# =====================================================================
step "1/9 host"
# =====================================================================
. /etc/os-release 2>/dev/null || true
info "time: $(date -u +%FT%TZ) | uptime: $(uptime -p 2>/dev/null || echo unknown)"
info "os: ${PRETTY_NAME:-unknown} | kernel: $(uname -r) | boots in journal: $(q journalctl --list-boots --no-pager | wc -l)"
info "memory: $(free -m 2>/dev/null | awk '/^Mem:/{printf "total=%sMB avail=%sMB", $2,$7}') | root disk free: $(df -h / 2>/dev/null | awk 'NR==2{print $4}')"

# =====================================================================
step "2/9 cloud-init status"
# =====================================================================
if ! have cloud-init; then
  bad "cloud-init binary not found on this VM"
  hint "cloud-init is not installed or not in PATH; on COS it is provided by the image, so check the image family."
  STATUS="missing"
else
  info "version: $(q T cloud-init --version | head -n 1)"
  STATUS_OUT=$(q T cloud-init status --long)
  STATUS=$(printf '%s\n' "$STATUS_OUT" | awk -F': *' '/^status:/{print $2; exit}')
  STATUS="${STATUS:-unknown}"
  case "$STATUS" in
    done)     okay "status: done" ;;
    running)  warn "status: running (still executing; re-run in a minute)" ;;
    disabled) warn "status: disabled" ;;
    *)        bad  "status: ${STATUS}" ;;
  esac
  printf '%s\n' "$STATUS_OUT" | excerpt 40
fi

# =====================================================================
step "3/9 per-stage results"
# =====================================================================
for f in /run/cloud-init/result.json /run/cloud-init/status.json; do
  if $SUDO test -r "$f" 2>/dev/null; then
    COMPACT=$(q $SUDO cat "$f" | tr -d '\n' | sed 's/  */ /g')
    ERRS=$(printf '%s' "$COMPACT" | grep -oE '"(errors|recoverable_errors)": ?(\[[^]]*\]|\{[^}]*\})' || true)
    if [ -n "$ERRS" ]; then
      info "${f##*/}: error fields"
      printf '%s\n' "$ERRS" | grep -vE '": ?(\[\]|\{\})$' | excerpt 20
      if printf '%s\n' "$ERRS" | grep -qvE '": ?(\[\]|\{\})$'; then warn "${f##*/} lists non-empty errors (shown above)"; else okay "${f##*/}: all error lists are empty"; fi
    else
      info "${f##*/}: $(printf '%s' "$COMPACT" | cut -c1-300)"
    fi
  else
    info "${f}: not readable or missing"
  fi
done

# =====================================================================
step "4/9 systemd units"
# =====================================================================
for u in cloud-init-local cloud-init-network cloud-init cloud-config cloud-final; do
  if systemctl list-unit-files "${u}.service" 2>/dev/null | grep -q "^${u}.service"; then
    R=$(q systemctl show "${u}.service" -p ActiveState -p Result -p ExecMainStatus | paste -sd' ' -)
    case "$R" in
      *Result=success*) okay "${u}: ${R}" ;;
      *)                bad  "${u}: ${R}" ;;
    esac
  fi
done
FAILED=$(q systemctl --failed --no-legend --plain | awk '{print $1}' | paste -sd' ' -)
if [ -n "$FAILED" ]; then warn "failed units on this boot: ${FAILED}"; else okay "no failed systemd units"; fi

# =====================================================================
step "5/9 logs"
# =====================================================================
ALL_LOGS=""
CLOG=/var/log/cloud-init.log
COUT=/var/log/cloud-init-output.log
if $SUDO test -r "$CLOG" 2>/dev/null; then
  C=$(q $SUDO grep -cE 'WARNING|ERROR|CRITICAL|Traceback' "$CLOG")
  info "${CLOG}: $(q $SUDO wc -l "$CLOG" | awk '{print $1}') lines, WARNING/ERROR/CRITICAL/Traceback lines: ${C:-0}"
  X=$(q $SUDO grep -nE "$ERR_PAT" "$CLOG" | san | tail -n "$N_LOG")
  ALL_LOGS+="$X"$'\n'
  printf '%s\n' "$X" | sed 's/^/[*]   | /'
else
  warn "${CLOG} not readable; using the journal instead"
  X=$(q $SUDO journalctl -b --no-pager -o cat -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final -p warning | san | tail -n "$N_LOG")
  ALL_LOGS+="$X"$'\n'
  printf '%s\n' "$X" | sed 's/^/[*]   | /'
fi
if $SUDO test -r "$COUT" 2>/dev/null; then
  info "${COUT} (output of bootcmd/runcmd/scripts), last ${N_OUT} lines:"
  X=$(q $SUDO tail -n "$N_OUT" "$COUT" | san)
  ALL_LOGS+="$X"$'\n'
  printf '%s\n' "$X" | sed 's/^/[*]   | /'
fi

# =====================================================================
step "6/9 user-data (contents are never printed)"
# =====================================================================
META="http://169.254.169.254/computeMetadata/v1"
if have curl; then
  R=$(q curl -s -m 4 -H 'Metadata-Flavor: Google' -o /dev/null -w '%{http_code} %{size_download}' "${META}/instance/attributes/user-data")
  case "$R" in
    "200 "*) okay "GCE metadata key user-data exists (${R#200 } bytes)" ;;
    "404 "*) bad "GCE metadata has NO user-data key" ; hint "Terraform must set metadata.user-data; check main.tf and that the apply finished." ;;
    *)       warn "could not query metadata (${R})" ;;
  esac
fi
UD=/var/lib/cloud/instance/user-data.txt
if $SUDO test -r "$UD" 2>/dev/null; then
  FIRST=$(q $SUDO head -n 1 "$UD")
  if [ "$FIRST" = "#cloud-config" ]; then okay "first line is #cloud-config"; else bad "first line is not #cloud-config (got: ${FIRST:0:30})"; hint "user-data must start with #cloud-config exactly, or cloud-init ignores it."; fi
  info "size: $(q $SUDO wc -c "$UD" | awk '{print $1}') bytes | top-level keys: $(q $SUDO grep -oE '^[a-z_]+:' "$UD" | tr -d ':' | sort -u | paste -sd' ' -)"
else
  warn "${UD} not found (cloud-init did not store user-data for this instance)"
fi
if have cloud-init; then
  SCH=$(q T $SUDO cloud-init schema --system)
  RC=$?
  if printf '%s' "$SCH" | grep -qiE 'unrecognized arguments|invalid choice|usage:'; then
    SCH=$(q T $SUDO cloud-init devel schema --system)
  fi
  if printf '%s' "$SCH" | grep -qiE 'valid cloud-config|Valid schema'; then
    okay "schema validation: user-data is valid"
  else
    warn "schema validation reported something (may be informational):"
    printf '%s\n' "$SCH" | excerpt 25
    ALL_LOGS+="$SCH"$'\n'
  fi
fi
SD=/var/lib/cloud/instance/scripts
if $SUDO test -d "$SD" 2>/dev/null; then
  info "generated scripts: $(q $SUDO ls "$SD" | paste -sd' ' -)"
  if $SUDO test -r "$SD/runcmd" 2>/dev/null; then
    info "last 3 commands of the runcmd script (its exit status decides success):"
    q $SUDO grep -vE '^\s*(#|$)' "$SD/runcmd" | tail -n 3 | excerpt 3
    RUNCMD_LAST=$(q $SUDO grep -vE '^\s*(#|$)' "$SD/runcmd" | tail -n 1)
  fi
fi

# =====================================================================
step "7/9 commands the user-data relies on"
# =====================================================================
for t in bash curl seq systemctl modprobe logger timeout mountpoint stat jq; do
  if have "$t"; then
    :
  else
    case "$t" in
      bash|curl|seq|systemctl) bad "missing command: ${t} (used by the user-data)" ;;
      logger)                  warn "missing command: logger" ;;
      *)                       info "command not present: ${t}" ;;
    esac
  fi
done
info "present: $(for t in bash curl seq systemctl modprobe logger timeout mountpoint stat jq systemd-cat; do have "$t" && printf '%s ' "$t"; done)"
if have logger; then
  q logger -t cloud-init-debug "probe"; okay "logger works (exit $?)"
fi
case "${RUNCMD_LAST:-}" in
  *logger*) have logger || { bad "the runcmd script's last command uses logger, which does not exist here"; hint "'logger' is missing and it is the LAST command of a runcmd/bootcmd block: it exits 127, so cloud-init reports status: error. Redirect to a file instead (... > /var/log/optimize-vm.log 2>&1 || true)."; } ;;
esac

# =====================================================================
step "8/9 what the user-data was supposed to set up"
# =====================================================================
if [ -r /run/net-mode ]; then info "net mode detected at boot: $(cat /run/net-mode)"; else warn "/run/net-mode missing (the bootcmd detection block did not run or failed)"; fi

RC_=/etc/resolv.conf
if [ -L "$RC_" ]; then RT="symlink"; else RT="file"; fi
NS=$(grep -c '^nameserver' "$RC_" 2>/dev/null || true)
DNS64=$(grep -c '2001:4860:4860::64' "$RC_" 2>/dev/null || true)
info "resolv.conf: ${RT}, ${NS} nameserver(s), DNS64 resolvers present: $([ "${DNS64:-0}" -gt 0 ] && echo yes || echo no) | systemd-resolved: $(q systemctl is-active systemd-resolved | head -n 1) ($(q systemctl is-enabled systemd-resolved | head -n 1))"
MODE=$(cat /run/net-mode 2>/dev/null || echo unknown)
if [ "$MODE" = "ipv4" ] && [ "${DNS64:-0}" -gt 0 ]; then bad "VM has an external IPv4 but resolv.conf still has the DNS64 resolvers"; hint "DNS64 on an IPv4 host breaks resolution; the bootcmd 'else' branch should have restored the default resolver."; fi
if [ "$MODE" = "ipv6only" ] && [ "${DNS64:-0}" -eq 0 ]; then warn "IPv6-only VM but DNS64 resolvers are not in resolv.conf"; fi
info "DNS check: $(getent hosts github.com </dev/null >/dev/null 2>&1 && echo 'github.com resolves' || echo 'github.com does NOT resolve')"

OV=/var/lib/optimize-vm/optimize-vm.sh
if [ -f "$OV" ]; then
  okay "optimize-vm.sh present ($(wc -l < "$OV") lines, $(stat -c %a "$OV" 2>/dev/null) perms)"
  if bash -n "$OV" 2>/dev/null; then okay "optimize-vm.sh passes bash -n"; else bad "optimize-vm.sh has a syntax error (write_files content got corrupted?)"; fi
else
  bad "${OV} missing: write_files did not run"
  hint "write_files failed or was skipped; look for 'write_files' / YAML errors in the log excerpts above."
fi
info "optimize-vm output (journal tag optimize-vm / log file):"
{ q $SUDO journalctl -b -t optimize-vm -t cloud-init-net --no-pager -o cat; [ -r /var/log/optimize-vm.log ] && cat /var/log/optimize-vm.log; } 2>/dev/null | excerpt "$N_LOG"
ALL_LOGS+="$(q $SUDO journalctl -b -t optimize-vm --no-pager -o cat | san)"$'\n'

D=/etc/docker/daemon.json
info "docker: $(q systemctl is-active docker | head -n 1) | containerd: $(q systemctl is-active containerd | head -n 1) | responds: $(T_SECS=10 q T docker info >/dev/null && echo yes || echo NO)"
if [ -r "$D" ]; then
  if have jq; then jq -e . "$D" >/dev/null 2>&1 && okay "daemon.json is valid JSON" || bad "daemon.json is NOT valid JSON (docker will not start)"; fi
fi
CT=/etc/containerd/config.toml
[ -r "$CT" ] && info "containerd CRI plugin disabled by tuning: $([ "$(grep -c '^disabled_plugins' "$CT" 2>/dev/null)" -gt 0 ] && echo yes || echo no)"
info "swap: $(swapon --show --noheadings 2>/dev/null | awk '{printf "%s(%s) ", $1,$3}')| swappiness: $(sysctl -n vm.swappiness 2>/dev/null)"

# =====================================================================
step "9/9 verdict"
# =====================================================================
chk() { printf '%s' "$ALL_LOGS" | grep -qiE "$1"; }
chk 'logger: (command )?not found|logger.*No such file' && { printf '%s\n' "${HINTS[@]:-}" | grep -q "'logger' is missing" || hint "'logger' was not found while running user-data (see the logs above). If it is the LAST command of a runcmd/bootcmd block, cloud-init reports status: error; redirect to a file or end the block with '|| true'."; }
chk 'Failed to run module scripts-user|Failed running .*/runcmd|runcmd.*(exited|non-zero)' && hint "runcmd failed: a runcmd script's result is its LAST command's exit status. End it with '|| true' or redirect output to a file."
chk 'Failed to run module bootcmd|Failed to run bootcmd|bootcmd.*(Failed|Error)' && hint "bootcmd failed: it also stops at a failing LAST command; add '|| true' to the end of each bootcmd block."
chk 'Failed loading yaml blob|mapping values are not allowed|could not find expected|cannot start any token|did not find expected' && hint "YAML syntax error in user-data: look at the first excerpt line with the line/column number."
chk 'Invalid cloud-config|Unexpected keys|is not valid under any of the given schemas|Additional properties' && hint "Schema warnings: a key is misspelled or misplaced; see the schema output in section 6."
chk 'Unrecognized user-data header' && hint "user-data header not recognized: it must begin with #cloud-config."
chk 'optimize-vm.sh: No such file|/var/lib/optimize-vm' && hint "optimize-vm.sh was not written: write_files likely failed (see YAML/schema hints)."
chk 'Permission denied' && hint "A command hit 'Permission denied': a path under /var/lib/docker is root-only, or the script ran unprivileged."

if [ "${#HINTS[@]}" -gt 0 ]; then
  info "likely causes / what to change:"
  declare -A SEEN=()
  i=1
  for h in "${HINTS[@]}"; do
    [ -n "${SEEN[$h]:-}" ] && continue
    SEEN[$h]=1
    echo "[!] ${i}. ${h}"
    i=$((i + 1))
  done
fi
if [ "$BAD" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  okay "no problems found; cloud-init status: ${STATUS}"
else
  info "summary: ${BAD} problem(s), ${WARN} warning(s); cloud-init status: ${STATUS}"
  [ "$STATUS" = "done" ] || info "run again with FULL=1 for longer log excerpts"
fi
echo "[+] debug-cloud-init done"
[ "$STRICT" = "1" ] && [ "$BAD" -gt 0 ] && exit 1
exit 0

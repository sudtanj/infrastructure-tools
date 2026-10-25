#!/bin/bash
# bash-scripts/upsert-github-runner.sh
# Runs ON the host over SSH: the GCP VM (gcp-bash-script-runner.yaml) or an Instabox machine
# (instabox-github-runner.yaml). Idempotent.
# Deploys the sudtanj/github-runner supervisor (builder-tools/github-runner): for every
# job it starts a fresh ghcr.io/actions/actions-runner container with a single-use JIT
# config, work dir in RAM, deleted after the job. Credentials are a GitHub App key (or a
# fine-grained PAT), so stopping and starting the VM never needs a new token.
#
# Required: GH_RUNNER_REPO (https://github.com/OWNER/REPO or OWNER/REPO; several repos
#   comma-separated, one supervisor each, the first keeping the original names) and either
#   GH_RUNNER_APP_ID + GH_RUNNER_APP_PRIVATE_KEY   GitHub App, permission Administration: RW
#   GH_RUNNER_PAT                                  fine-grained PAT, Administration: RW on the repo
# Optional: GH_RUNNER_NAME (runner name prefix), GH_RUNNER_LABELS, GH_RUNNER_CPUS,
#   GH_RUNNER_MEMORY, GH_RUNNER_MEMORY_SWAP, GH_RUNNER_WORK_SIZE, GH_RUNNER_TMP_SIZE,
#   GH_RUNNER_NO_SUDO, GH_RUNNER_NETWORK, GH_RUNNER_IMAGE, GH_RUNNER_DNS,
#   GH_RUNNER_HOST_RAM_ONLY=1 (swap off + system journal in RAM; only for a runner-only host).

set -euo pipefail

SUPERVISOR_IMAGE="${GH_RUNNER_SUPERVISOR_IMAGE:-sudtanj/github-runner:latest}"
SUPERVISOR_NAME="gh-runner-supervisor"
LEGACY_CONTAINER="${GH_RUNNER_CONTAINER_NAME:-github-runner}"   # the old myoung34 runner
SECRETS_DIR="/var/lib/gh-runner"   # /var survives reboots on COS, /etc does not

REPO="${GH_RUNNER_REPO:-}"
APP_ID="${GH_RUNNER_APP_ID:-}"
APP_KEY="${GH_RUNNER_APP_PRIVATE_KEY:-}"
PAT="${GH_RUNNER_PAT:-}"
PREFIX="${GH_RUNNER_NAME:-${TS_HOSTNAME:-gcp-free-tier-vm}}"
LABELS="${GH_RUNNER_LABELS:-self-hosted,linux,x64,gcp-free-tier}"

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

if [ "$(id -u)" = 0 ]; then SU=(); else SU=(sudo -n); fi
if docker info >/dev/null 2>&1; then DK=(docker); else DK=(sudo -n docker); fi
dk() { "${DK[@]}" "$@"; }

status "upsert github runner start"

step "checking required env"
# GH_RUNNER_REPO may list several repos, comma-separated; each gets its own supervisor.
REPOS=()
IFS=',' read -ra REPO_LIST <<< "$REPO"
for r in "${REPO_LIST[@]}"; do
  r="${r//[[:space:]]/}"; r="${r#https://github.com/}"; r="${r%.git}"; r="${r%/}"
  [ -n "$r" ] || continue
  case "$r" in
    */*) REPOS+=("$r") ;;
    *) fail "GH_RUNNER_REPO must be https://github.com/OWNER/REPO or OWNER/REPO (several: comma-separated)" ;;
  esac
done
[ "${#REPOS[@]}" -gt 0 ] || fail "GH_RUNNER_REPO must be https://github.com/OWNER/REPO or OWNER/REPO (several: comma-separated)"
ok "repo set (${#REPOS[@]})"
if [ -n "$APP_ID" ] && [ -n "$APP_KEY" ]; then
  AUTH_MODE=app
elif [ -n "$PAT" ]; then
  AUTH_MODE=pat
else
  fail "missing credentials: set GH_RUNNER_APP_ID + GH_RUNNER_APP_PRIVATE_KEY (recommended) or GH_RUNNER_PAT"
fi
case "$APP_KEY" in
  ""|*"PRIVATE KEY-----"*) ;;
  *) fail "GH_RUNNER_APP_PRIVATE_KEY must be the whole .pem file, BEGIN/END lines included" ;;
esac
ok "credentials: ${AUTH_MODE}"

step "checking docker daemon"
timeout 20 "${DK[@]}" version -f '{{.Server.Version}}' >/dev/null 2>&1 || fail "docker daemon is not available"
ok "docker ready"

# Docker has to come up by itself after a reboot (COS does this already; Debian on Instabox
# may not), so --restart can bring the supervisor back.
if [ -d /run/systemd/system ] && ! systemctl is-enabled -q docker 2>/dev/null; then
  if "${SU[@]}" systemctl enable docker >/dev/null 2>&1; then ok "docker enabled at boot"; else warn "could not enable docker at boot"; fi
fi

# Opt-in for hosts that only run the runner (Instabox): job RAM can't swap anyway (cgroup
# memory-swap = memory); this also keeps the rest of the host's memory and its system journal
# off the disk. Not for the GCP e2-micro, which needs its swapfile.
if [ "${GH_RUNNER_HOST_RAM_ONLY:-0}" = 1 ]; then
  step "keeping memory and logs off the disk (no swap, journal in RAM)"
  if [ -n "$(swapon --noheadings 2>/dev/null)" ]; then
    if "${SU[@]}" swapoff -a; then ok "swap off"; else warn "could not turn swap off"; fi
  else
    ok "no swap"
  fi
  # Stays off after a reboot.
  if [ -f /etc/fstab ] && grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
    "${SU[@]}" sed -i -E 's/^([^#].*[[:space:]]swap[[:space:]].*)$/# \1/' /etc/fstab && ok "swap removed from /etc/fstab"
  fi
  if [ -d /run/systemd/system ]; then
    if printf '[Journal]\nStorage=volatile\nRuntimeMaxUse=16M\n' \
        | "${SU[@]}" sh -c 'install -d /etc/systemd/journald.conf.d && cat > /etc/systemd/journald.conf.d/gh-runner-ram.conf' \
      && "${SU[@]}" systemctl restart systemd-journald >/dev/null 2>&1; then
      "${SU[@]}" rm -rf /var/log/journal   # what was written before this setting
      ok "system journal kept in RAM only"
    else
      warn "could not move the system journal to RAM"
    fi
  fi
fi

step "storing credentials in ${SECRETS_DIR} (root only)"
# Through stdin, never argv. Only the supervisor container mounts this directory;
# job containers never see it.
"${SU[@]}" install -d -m 0700 -o root -g root "$SECRETS_DIR"
if [ "$AUTH_MODE" = app ]; then
  printf '%s\n' "$APP_KEY" | "${SU[@]}" sh -c "umask 077; cat > '${SECRETS_DIR}/app.pem'"
  "${SU[@]}" rm -f "${SECRETS_DIR}/pat"
else
  printf '%s' "$PAT" | "${SU[@]}" sh -c "umask 077; cat > '${SECRETS_DIR}/pat'"
  "${SU[@]}" rm -f "${SECRETS_DIR}/app.pem"
  APP_ID=""
fi
ok "credentials stored"

step "pulling ${SUPERVISOR_IMAGE}"
if ! timeout 600 "${DK[@]}" pull -q "$SUPERVISOR_IMAGE" >/dev/null 2>&1; then
  dk image inspect "$SUPERVISOR_IMAGE" >/dev/null 2>&1 || fail "could not pull ${SUPERVISOR_IMAGE}"
  warn "pull failed, using the cached image"
fi
ok "supervisor image present"

# Settings shared by every supervisor; unset ones fall back to the defaults in supervisor.sh.
BASE_ENV=(-e "GH_RUNNER_NAME_PREFIX=${PREFIX}" -e "GH_RUNNER_LABELS=${LABELS}")
if [ -n "$APP_ID" ]; then BASE_ENV+=(-e "GH_RUNNER_APP_ID=${APP_ID}"); fi
for v in CPUS MEMORY MEMORY_SWAP WORK_SIZE TMP_SIZE NO_SUDO NETWORK IMAGE DNS; do
  val="GH_RUNNER_${v}"
  if [ -n "${!val:-}" ]; then BASE_ENV+=(-e "GH_RUNNER_${v}=${!val}"); fi
done
# The first repo keeps the original container names, so a single-repo host is unchanged;
# repo N (N >= 2) gets gh-runner-supervisor-N and its job container gh-runner-job-N.
# Same name prefix on every repo is fine: each supervisor only sees its own repo's runners.
sv_name() { if [ "$1" -eq 0 ]; then echo "$SUPERVISOR_NAME"; else echo "${SUPERVISOR_NAME}-$(($1 + 1))"; fi; }
run_args() {   # $1 = index into REPOS
  RUN_ARGS=(--init --network host --read-only
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=8m
    --cap-drop ALL --security-opt no-new-privileges:true
    --cpus 0.20 --memory 64m --memory-swap 64m --pids-limit 64
    -v /var/run/docker.sock:/var/run/docker.sock
    -v "${SECRETS_DIR}:/run/secrets/gh-runner:ro"
    "${BASE_ENV[@]}" -e "GH_RUNNER_REPO=${REPOS[$1]}")
  if [ "$1" -gt 0 ]; then RUN_ARGS+=(-e "GH_RUNNER_JOB_CONTAINER=gh-runner-job-$(($1 + 1))"); fi
}

step "checking GitHub access with these credentials"
for i in "${!REPOS[@]}"; do
  run_args "$i"
  if ! CHECK=$(dk run --rm "${RUN_ARGS[@]}" "$SUPERVISOR_IMAGE" check 2>&1); then
    printf '%s\n' "$CHECK" | grep -E '^\[[*+!x]\] ' >&2 || true
    fail "credential check failed for repo $((i + 1)); the running runner(s) (if any) were left untouched"
  fi
  printf '%s\n' "$CHECK" | grep -E '^\[[*+!x]\] ' || true
done

step "removing old runner containers"
# Every supervisor, including ones for repos no longer listed.
for c in "$LEGACY_CONTAINER" $(dk ps -a --format '{{.Names}}' | grep -E "^${SUPERVISOR_NAME}(-[0-9]+)?\$" || true); do
  if dk ps -a --format '{{.Names}}' | grep -qx "$c"; then
    dk rm -f "$c" >/dev/null 2>&1 || true
    ok "removed ${c}"
  fi
done
# A job container that is running now is left alone: the new supervisor waits for it.

for i in "${!REPOS[@]}"; do
  name=$(sv_name "$i")
  run_args "$i"
  step "starting ${name} (repo $((i + 1)) of ${#REPOS[@]})"
  # No Docker log file on disk: the supervisor keeps its log in its own RAM /tmp
  # (GH_RUNNER_LOG_FILE, ~2 MiB rotated), and job containers log nowhere.
  dk run -d --name "$name" --restart unless-stopped --log-driver none \
    -e GH_RUNNER_LOG_FILE=/tmp/supervisor.log \
    "${RUN_ARGS[@]}" "$SUPERVISOR_IMAGE" run >/dev/null || fail "failed to start ${name}"
done
svlog() { dk exec "$1" cat /tmp/supervisor.log 2>/dev/null || true; }

for i in "${!REPOS[@]}"; do
  name=$(sv_name "$i")
  step "waiting for ${name}'s first runner to come online"
  for _ in $(seq 1 45); do
    sleep 2
    STATE=$(dk inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo missing)
    [ "$STATE" = running ] || break
    svlog "$name" | grep -qE 'online, waiting for a job|already running' && break
  done
  svlog "$name" | tail -n 20 | grep -E '^\[[*+!x]\] ' || true
  [ "$STATE" = running ] || fail "${name} is ${STATE} (its log was in RAM; run it with: docker run --rm ... ${SUPERVISOR_IMAGE} check)"
  if svlog "$name" | grep -qE 'online, waiting for a job|already running'; then
    ok "${name} is up; jobs with runs-on: [${LABELS}] in repo $((i + 1)) will run here"
  else
    warn "${name} is running but no runner is online yet (pulling the runner image?); check: docker exec ${name} cat /tmp/supervisor.log"
  fi
done

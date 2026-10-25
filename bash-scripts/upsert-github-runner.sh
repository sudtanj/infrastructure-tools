#!/bin/bash
# bash-scripts/upsert-github-runner.sh
# Runs ON the host over SSH: the GCP VM (gcp-bash-script-runner.yaml) or an Instabox machine
# (instabox-github-runner.yaml). Idempotent.
# Deploys the sudtanj/github-runner supervisor (builder-tools/github-runner): for every
# job it starts a fresh ghcr.io/actions/actions-runner container with a single-use JIT
# config, work dir in RAM, deleted after the job. Credentials are a GitHub App key (or a
# fine-grained PAT), so stopping and starting the VM never needs a new token.
#
# Required: GH_RUNNER_REPO (https://github.com/OWNER/REPO or OWNER/REPO) and either
#   GH_RUNNER_APP_ID + GH_RUNNER_APP_PRIVATE_KEY   GitHub App, permission Administration: RW
#   GH_RUNNER_PAT                                  fine-grained PAT, Administration: RW on the repo
# Optional: GH_RUNNER_NAME (runner name prefix), GH_RUNNER_LABELS, GH_RUNNER_CPUS,
#   GH_RUNNER_MEMORY, GH_RUNNER_MEMORY_SWAP, GH_RUNNER_WORK_SIZE, GH_RUNNER_TMP_SIZE,
#   GH_RUNNER_NO_SUDO, GH_RUNNER_NETWORK, GH_RUNNER_IMAGE, GH_RUNNER_DNS.

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
REPO="${REPO#https://github.com/}"; REPO="${REPO%.git}"; REPO="${REPO%/}"
case "$REPO" in
  */*) ok "repo set" ;;
  *) fail "GH_RUNNER_REPO must be https://github.com/OWNER/REPO or OWNER/REPO" ;;
esac
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

# Settings for the supervisor; unset ones fall back to the defaults in supervisor.sh.
ENV_ARGS=(-e "GH_RUNNER_REPO=${REPO}" -e "GH_RUNNER_NAME_PREFIX=${PREFIX}" -e "GH_RUNNER_LABELS=${LABELS}")
if [ -n "$APP_ID" ]; then ENV_ARGS+=(-e "GH_RUNNER_APP_ID=${APP_ID}"); fi
for v in CPUS MEMORY MEMORY_SWAP WORK_SIZE TMP_SIZE NO_SUDO NETWORK IMAGE DNS; do
  val="GH_RUNNER_${v}"
  if [ -n "${!val:-}" ]; then ENV_ARGS+=(-e "GH_RUNNER_${v}=${!val}"); fi
done
RUN_ARGS=(--init --network host --read-only
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=8m
  --cap-drop ALL --security-opt no-new-privileges:true
  --cpus 0.20 --memory 64m --memory-swap 64m --pids-limit 64
  -v /var/run/docker.sock:/var/run/docker.sock
  -v "${SECRETS_DIR}:/run/secrets/gh-runner:ro"
  "${ENV_ARGS[@]}")

step "checking GitHub access with these credentials"
if ! CHECK=$(dk run --rm "${RUN_ARGS[@]}" "$SUPERVISOR_IMAGE" check 2>&1); then
  printf '%s\n' "$CHECK" | grep -E '^\[[*+!x]\] ' >&2 || true
  fail "credential check failed; the running runner (if any) was left untouched"
fi
printf '%s\n' "$CHECK" | grep -E '^\[[*+!x]\] ' || true

step "removing old runner containers"
for c in "$LEGACY_CONTAINER" "$SUPERVISOR_NAME"; do
  if dk ps -a --format '{{.Names}}' | grep -qx "$c"; then
    dk rm -f "$c" >/dev/null 2>&1 || true
    ok "removed ${c}"
  fi
done
# A job container that is running now is left alone: the new supervisor waits for it.

step "starting ${SUPERVISOR_NAME}"
dk run -d --name "$SUPERVISOR_NAME" --restart unless-stopped \
  --log-driver json-file --log-opt max-size=2m --log-opt max-file=2 \
  "${RUN_ARGS[@]}" "$SUPERVISOR_IMAGE" run >/dev/null || fail "failed to start ${SUPERVISOR_NAME}"

step "waiting for the first runner to come online"
for _ in $(seq 1 45); do
  sleep 2
  STATE=$(dk inspect -f '{{.State.Status}}' "$SUPERVISOR_NAME" 2>/dev/null || echo missing)
  [ "$STATE" = running ] || break
  dk logs "$SUPERVISOR_NAME" 2>&1 | grep -qE 'online, waiting for a job|already running' && break
done
dk logs --tail 20 "$SUPERVISOR_NAME" 2>&1 | grep -E '^\[[*+!x]\] ' || true
[ "$STATE" = running ] || fail "${SUPERVISOR_NAME} is ${STATE}"
if dk logs "$SUPERVISOR_NAME" 2>&1 | grep -qE 'online, waiting for a job|already running'; then
  ok "github runner supervisor is up; jobs with runs-on: [${LABELS}] will run here"
else
  warn "supervisor is running but no runner is online yet (pulling the runner image?); check: docker logs ${SUPERVISOR_NAME}"
fi

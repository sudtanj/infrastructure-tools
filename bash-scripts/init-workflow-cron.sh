#!/bin/bash
# bash-scripts/init-workflow-cron.sh
# Idempotent deploy/update of workflow-cron (sudtanj/workflow-cron, see builder-tools/workflow-cron/):
# a distroless clock that dispatches this repo's GitHub Actions workflows at the exact minute,
# instead of relying on GitHub's `schedule:` trigger, which starts runs late.
#
# Runs on the GCP VM (amd64) or the Orange Pi (arm64). Deploy it to ONE of them: on both, every
# workflow would start twice. Remove it from the other with `docker rm -f workflow-cron`.
#
# Security model (this repo is public and its Actions logs are public):
#   - The GitHub and Telegram tokens are never printed. They reach the container as environment
#     variables (`docker run -e NAME`, no value on the command line), so only root on the device
#     can read them back (`docker inspect`).
#
# Env (the job list and time zone are below, in this file: edit them here and re-run):
#   WORKFLOW_CRON_GITHUB_TOKEN   token that may dispatch this repo's workflows (Actions: write, or a classic
#                                PAT with `repo` + `workflow`) (required; the GCP and Orange Pi runners pass GH_TOKEN
#                                unless a WORKFLOW_CRON_GITHUB_TOKEN secret exists)
#   WORKFLOW_CRON_TELEGRAM_TOKEN, WORKFLOW_CRON_TELEGRAM_CHAT_ID
#                                optional: a Telegram message when a dispatch fails for good
#   WORKFLOW_CRON_IMAGE          default sudtanj/workflow-cron:latest

set -euo pipefail

CONTAINER_NAME="workflow-cron"
IMAGE="${WORKFLOW_CRON_IMAGE:-sudtanj/workflow-cron:latest}"
MEMORY_LIMIT="32m"
CPU_LIMIT="0.10"

# What runs when, in TZ_NAME. These replace the workflows' GitHub `schedule:` (all but
# opi-uptime-check.yaml, which watches this Orange Pi and so must not depend on it). One job per line:
#   <min> <hour> <dom> <month> <dow> <workflow file> [input=value ...]
TZ_NAME="Asia/Jakarta"
JOBS='
0 *    * * *  typescript-worker-run.yaml
0 7,17 * * *  android-emulator-session.yaml exit_node=true autoplay=true
0 5    * * *  android-emulator-session.yaml exit_node=true autoplay=true pinedrama=false
0 8,11,17,18 * * 1-5  commute-traffic.yaml skip_off_days=true
# Every 5-30 minutes.
*/15 * * * *  cloudflare-private-deploy.yaml
*/5  * * * *  terraform-free-tier-oci.yaml
*/30 * * * *  vercel-private-deploy.yaml
7,37 * * * *  apps-private-build.yaml
*/30 * * * *  workflow-cleanup-job.yaml
# Builders and chores (their old UTC crons, +7 hours).
23 1,7,13,19 * * *  builder-tools-mi3-padavan-firmware-builder.yml only_if_updated=true
17 11 * * 1   builder-tools-docker-publish.yml no_cache=true
41 12 * * 1   builder-tools-opi-zero3-armbian.yml only_if_updated=true
23 9  * * 1   search-engine-register.yaml
# Twice a day: it posts only when the last post is 40+ hours old, so a failed run is retried.
17 8,20 * * *  tanoitcorp-blog.yaml only_if_due=true
'

export WORKFLOW_CRON_JOBS="$JOBS"
export WORKFLOW_CRON_TZ="$TZ_NAME"
export WORKFLOW_CRON_REPO="sudtanj/infrastructure-tools"
export WORKFLOW_CRON_REF="main"
export WORKFLOW_CRON_GITHUB_TOKEN="${WORKFLOW_CRON_GITHUB_TOKEN:-}"
export WORKFLOW_CRON_TELEGRAM_TOKEN="${WORKFLOW_CRON_TELEGRAM_TOKEN:-}"
export WORKFLOW_CRON_TELEGRAM_CHAT_ID="${WORKFLOW_CRON_TELEGRAM_CHAT_ID:-}"
ENV_OPTS=(-e WORKFLOW_CRON_JOBS -e WORKFLOW_CRON_TZ -e WORKFLOW_CRON_REPO -e WORKFLOW_CRON_REF
  -e WORKFLOW_CRON_GITHUB_TOKEN -e WORKFLOW_CRON_TELEGRAM_TOKEN -e WORKFLOW_CRON_TELEGRAM_CHAT_ID)

status() { printf '%s\n' "[*] $*"; }
step()   { printf '%s\n' "[>] $*"; }
ok()     { printf '%s\n' "[+] $*"; }
debug()  { [ "${INIT_DEBUG:-0}" = "1" ] && printf '%s\n' "[d] $*" || true; }
warn()   { printf '%s\n' "[!] $*" >&2; }
fail()   { printf '%s\n' "[x] $*" >&2; exit 1; }

if [ "$(id -u)" -eq 0 ] || docker info >/dev/null 2>&1; then
  DOCKER=(docker)
else
  DOCKER=(sudo -E docker)
fi

# workflow-cron prints "<time> [x] message"; drop the time so the runner shows the line.
untime() { sed -E 's/^[^[]*(\[[*+!x]\] )/\1/' | sed "s/^\[\([*+]\)\] /[$1] /"; }

status "init workflow-cron start"

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
step "preflight checks"
"${DOCKER[@]}" info >/dev/null 2>&1 || fail "docker daemon is not available"
[ -n "$WORKFLOW_CRON_GITHUB_TOKEN" ] || fail "WORKFLOW_CRON_GITHUB_TOKEN is not set"
ok "docker ready"

# ---------------------------------------------------------------------------
# 2. Image + config check (the binary validates the job list and prints the next runs)
# ---------------------------------------------------------------------------
step "pulling ${IMAGE}"
PULLED=0
for attempt in 1 2 3; do
  if "${DOCKER[@]}" pull "$IMAGE" >/dev/null 2>&1; then PULLED=1; break; fi
  warn "pull failed (attempt ${attempt}/3)"
  [ "$attempt" -lt 3 ] && sleep $(( attempt * 5 ))
done
[ "$PULLED" = "1" ] || fail "failed to pull ${IMAGE}"
IMAGE_ID="$("${DOCKER[@]}" image inspect -f '{{.Id}}' "$IMAGE")"
ok "image ready"

step "checking the job list"
CHECK_OUT="$("${DOCKER[@]}" run --rm -e WORKFLOW_CRON_JOBS -e WORKFLOW_CRON_TZ "$IMAGE" -check 2>&1)" \
  || { printf '%s\n' "$CHECK_OUT" | untime '!' >&2; fail "invalid JOBS / TZ_NAME in this script"; }
printf '%s\n' "$CHECK_OUT" | untime '*'

# ---------------------------------------------------------------------------
# 3. Skip the restart when nothing changed
# ---------------------------------------------------------------------------
WANT_SUM="$(printf '%s\n' "$IMAGE_ID" "$WORKFLOW_CRON_JOBS" "$WORKFLOW_CRON_TZ" "$WORKFLOW_CRON_REPO" \
  "$WORKFLOW_CRON_REF" "$WORKFLOW_CRON_GITHUB_TOKEN" "$WORKFLOW_CRON_TELEGRAM_TOKEN" \
  "$WORKFLOW_CRON_TELEGRAM_CHAT_ID" "$MEMORY_LIMIT" "$CPU_LIMIT" "v1" | sha256sum | awk '{print $1}')"
HAVE_SUM="$("${DOCKER[@]}" inspect -f '{{index .Config.Labels "workflow-cron.config"}}' "$CONTAINER_NAME" 2>/dev/null || true)"
STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"

if [ "$WANT_SUM" = "$HAVE_SUM" ] && [ "$STATE" = "running" ]; then
  ok "${CONTAINER_NAME} already running with the current image and settings"
else
  debug "recreate reason: state=${STATE}, config $([ "$WANT_SUM" = "$HAVE_SUM" ] && echo same || echo changed)"
  step "replacing ${CONTAINER_NAME}"
  "${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  "${DOCKER[@]}" run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --label "workflow-cron.config=${WANT_SUM}" \
    "${ENV_OPTS[@]}" \
    --read-only \
    --cpus "$CPU_LIMIT" --cpu-shares 256 \
    --memory "$MEMORY_LIMIT" --memory-swap "$MEMORY_LIMIT" \
    --pids-limit 32 \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-driver json-file --log-opt max-size=1m --log-opt max-file=2 \
    "$IMAGE" >/dev/null \
    || fail "failed to start ${CONTAINER_NAME}"
fi

# ---------------------------------------------------------------------------
# 4. Verify: it checked the token and workflows against GitHub, and stays up
# ---------------------------------------------------------------------------
step "checking ${CONTAINER_NAME} stays up"
READY=0
for _ in $(seq 1 15); do
  STATE="$("${DOCKER[@]}" inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
  [ "$STATE" = "running" ] || break
  # Read first: `docker logs | grep -q` fails under pipefail when grep exits early.
  LOGS="$("${DOCKER[@]}" logs "$CONTAINER_NAME" 2>&1 || true)"
  if grep -q '\[+\] ready' <<<"$LOGS"; then READY=1; break; fi
  sleep 2
done
if [ "$READY" != "1" ]; then
  warn "state: ${STATE}"
  "${DOCKER[@]}" logs --tail 15 "$CONTAINER_NAME" 2>&1 | untime '!' >&2 || true
  fail "${CONTAINER_NAME} did not become ready (token without Actions access, or a workflow name is wrong)"
fi
[ "${INIT_DEBUG:-0}" = "1" ] && { "${DOCKER[@]}" logs --tail 10 "$CONTAINER_NAME" 2>&1 | untime d || true; }

MEM="$("${DOCKER[@]}" stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null || true)"
echo "[>] summary"
echo "[*] image: ${IMAGE}"
echo "[*] repo: ${WORKFLOW_CRON_REPO}@${WORKFLOW_CRON_REF}, times in ${WORKFLOW_CRON_TZ}"
echo "[*] telegram alerts: $([ -n "$WORKFLOW_CRON_TELEGRAM_TOKEN" ] && [ -n "$WORKFLOW_CRON_TELEGRAM_CHAT_ID" ] && echo on || echo off)"
echo "[*] memory: ${MEM:-unknown} (cap ${MEMORY_LIMIT})"
ok "init workflow-cron done"

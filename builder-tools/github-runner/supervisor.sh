#!/usr/bin/env bash
# gh-runner-supervisor: keeps one ephemeral GitHub Actions runner available for a repo.
#
# Loop: mint a short-lived token from a GitHub App key (or a PAT) -> remove this host's
# offline runners -> ask GitHub for a single-use JIT runner config -> start a fresh
# container from the official runner image with that config -> wait for it to run one
# job and exit -> delete the container (and with it the RAM work dir) -> repeat.
#
# Nothing has to be re-authorised by hand: the App key does not expire, every runner
# registration is new and single-use, and Docker's restart policy brings this container
# back after the VM is stopped and started. A host that was suspended or lost its network
# (an Instabox machine resuming, a laptop waking) gets a new runner if the old one doesn't
# reconnect by itself within a few minutes.
#
# Usage: gh-runner-supervisor run     (default) supervise forever
#        gh-runner-supervisor check   verify config + GitHub access, then exit
#
# Credentials are read from files, never from the environment, so `docker inspect`
# of this container does not show them:
#   GH_RUNNER_APP_ID + GH_RUNNER_APP_KEY_FILE   GitHub App (recommended), key in PEM
#   GH_RUNNER_PAT_FILE                          fine-grained PAT (Administration: RW)

set -euo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"
REPO="${GH_RUNNER_REPO:-}"
REPO="${REPO#https://github.com/}"; REPO="${REPO%.git}"; REPO="${REPO%/}"
APP_ID="${GH_RUNNER_APP_ID:-}"
APP_KEY_FILE="${GH_RUNNER_APP_KEY_FILE:-/run/secrets/gh-runner/app.pem}"
PAT_FILE="${GH_RUNNER_PAT_FILE:-/run/secrets/gh-runner/pat}"

PREFIX="${GH_RUNNER_NAME_PREFIX:-$(hostname)}"
LABELS="${GH_RUNNER_LABELS:-self-hosted,linux,x64}"
GROUP_ID="${GH_RUNNER_GROUP_ID:-1}"
IMAGE="${GH_RUNNER_IMAGE:-ghcr.io/actions/actions-runner:latest}"
JOB_NAME="${GH_RUNNER_JOB_CONTAINER:-gh-runner-job}"
NETWORK="${GH_RUNNER_NETWORK:-host}"
CPUS="${GH_RUNNER_CPUS:-0.50}"
MEMORY="${GH_RUNNER_MEMORY:-512m}"
# Same as MEMORY = the job can't swap, so nothing in its RAM (tmpfs included) reaches disk.
MEMORY_SWAP="${GH_RUNNER_MEMORY_SWAP:-$MEMORY}"
PIDS="${GH_RUNNER_PIDS:-1024}"
WORK_SIZE="${GH_RUNNER_WORK_SIZE:-1g}"
TMP_SIZE="${GH_RUNNER_TMP_SIZE:-256m}"
NO_SUDO="${GH_RUNNER_NO_SUDO:-0}"
DNS="${GH_RUNNER_DNS:-}"
PULL_HOURS="${GH_RUNNER_PULL_HOURS:-6}"
RUNNER_UID=1001   # the "runner" user in ghcr.io/actions/actions-runner

ts()   { date -u +%H:%M:%S; }
info() { printf '[*] %s %s\n' "$(ts)" "$*"; }
ok()   { printf '[+] %s %s\n' "$(ts)" "$*"; }
warn() { printf '[!] %s %s\n' "$(ts)" "$*" >&2; }
fail() { printf '[x] %s %s\n' "$(ts)" "$*" >&2; exit 1; }

HDR=$(mktemp)   # auth headers live in files on tmpfs, not on curl's command line
trap 'rm -f "$HDR"' EXIT

# ---------- GitHub API ----------
AUTH=""
# gh_api METHOD PATH [JSON]: prints the response body; non-2xx -> message on stderr, return 1.
gh_api() {
  local method=$1 path=$2 body=${3:-} out code
  local args=(-sS -m 30 -w '\n%{http_code}' -X "$method"
    -H "@$HDR" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  printf 'Authorization: Bearer %s\n' "$AUTH" > "$HDR"
  out=$(curl "${args[@]}" "${API}${path}") || { warn "GitHub API ${method} ${path%%\?*}: unreachable"; return 1; }
  code=$(tail -n1 <<<"$out"); out=$(sed '$d' <<<"$out")
  if [ "${code:0:1}" != "2" ]; then
    warn "GitHub API ${method} ${path%%\?*} -> HTTP ${code}: $(jq -r '.message? // empty' <<<"$out" 2>/dev/null | head -c 200)"
    return 1
  fi
  printf '%s' "$out"
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
app_jwt() {
  local now unsigned
  now=$(date +%s)
  unsigned="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url).$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)"
  printf '%s.%s' "$unsigned" "$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$APP_KEY_FILE" -binary | b64url)"
}

TOKEN=""; TOKEN_EXP=0
# Sets AUTH to a usable token. App installation tokens last 1h and are cached for 55 min,
# scoped down to this one repo and the one permission runner registration needs.
token() {
  local now inst resp
  if [ -z "$APP_ID" ]; then AUTH=$(tr -d '\r\n' < "$PAT_FILE"); return 0; fi
  now=$(date +%s)
  if [ -n "$TOKEN" ] && [ "$now" -lt "$TOKEN_EXP" ]; then AUTH=$TOKEN; return 0; fi
  AUTH=$(app_jwt) || { warn "could not sign the App JWT (is ${APP_KEY_FILE} a valid PEM key?)"; return 1; }
  resp=$(gh_api GET "/repos/${REPO}/installation") || { warn "is the GitHub App installed on ${REPO}?"; return 1; }
  inst=$(jq -r .id <<<"$resp")
  resp=$(gh_api POST "/app/installations/${inst}/access_tokens" \
    "$(jq -nc --arg r "${REPO#*/}" '{repositories:[$r], permissions:{administration:"write"}}')") \
    || { warn "the App needs the repository permission Administration: Read and write"; return 1; }
  TOKEN=$(jq -r .token <<<"$resp"); TOKEN_EXP=$((now + 3300)); AUTH=$TOKEN
}

# Offline runners named PREFIX or PREFIX-* are leftovers from this host (VM stopped
# mid-job or while idle, old non-ephemeral runner): nothing of ours is running now.
remove_stale() {
  local list id name
  list=$(gh_api GET "/repos/${REPO}/actions/runners?per_page=100") || return 1
  while read -r id name; do
    [ -n "$id" ] || continue
    if gh_api DELETE "/repos/${REPO}/actions/runners/${id}" >/dev/null; then ok "removed stale runner ${name}"; fi
  done < <(jq -r --arg p "$PREFIX" '.runners[]
      | select(.status == "offline" and (.name == $p or (.name | startswith($p + "-"))))
      | "\(.id) \(.name)"' <<<"$list")
}

# ---------- runner image ----------
LAST_PULL=0
pull_image() {
  local now; now=$(date +%s)
  if docker image inspect "$IMAGE" >/dev/null 2>&1 && [ $((now - LAST_PULL)) -lt $((PULL_HOURS * 3600)) ]; then return 0; fi
  if docker pull -q "$IMAGE" >/dev/null 2>&1; then
    LAST_PULL=$now; ok "runner image up to date: ${IMAGE}"
  elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
    LAST_PULL=$((now - PULL_HOURS * 3600 + 3600))   # try again in an hour
    warn "could not pull ${IMAGE}; using the cached copy"
  else
    warn "could not pull ${IMAGE} and no cached copy"; return 1
  fi
}

# ---------- watchdog ----------
# wait_job RUNNER_ID: waits for the job container to exit and sets JOB_RC to its exit code.
# It also checks with GitHub every minute. After the host was suspended, paused or offline,
# the runner normally reconnects by itself; if GitHub still shows it offline 3 minutes later
# (or has deleted it: unused ephemeral runners are removed after a day offline), the container
# is replaced with a freshly registered runner (JOB_RC=stale).
wait_job() {
  local id=$1 offline=0 st
  while [ "$(docker inspect -f '{{.State.Running}}' "$JOB_NAME" 2>/dev/null)" = "true" ]; do
    sleep 60
    token >/dev/null 2>&1 || continue   # GitHub unreachable: can't tell, keep waiting
    if st=$(gh_api GET "/repos/${REPO}/actions/runners/${id}" 2>/dev/null); then
      if [ "$(jq -r .status <<<"$st")" = online ]; then offline=0; else offline=$((offline + 1)); fi
    elif [ "$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -H "@$HDR" "${API}/repos/${REPO}/actions/runners/${id}" 2>/dev/null)" = 404 ]; then
      offline=3
    fi
    if [ "$offline" -ge 3 ]; then
      warn "GitHub shows the runner offline for 3 minutes; replacing it with a new registration"
      docker rm -f "$JOB_NAME" >/dev/null 2>&1 || true
      gh_api DELETE "/repos/${REPO}/actions/runners/${id}" >/dev/null 2>&1 || true
      JOB_RC=stale; return
    fi
  done
  JOB_RC=$(docker inspect -f "{{.State.ExitCode}}" "$JOB_NAME" 2>/dev/null || echo "?")
}

# ---------- one job ----------
run_one() {
  local name body resp envf rc rid
  name="${PREFIX}-$(date -u +%m%d%H%M%S)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
  body=$(jq -nc --arg n "$name" --argjson g "$GROUP_ID" --arg l "$LABELS" \
    '{name:$n, runner_group_id:$g, work_folder:"_work",
      labels:($l | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}')
  resp=$(gh_api POST "/repos/${REPO}/actions/runners/generate-jitconfig" "$body") || return 1
  rid=$(jq -r .runner.id <<<"$resp")

  # The JIT config is single-use and dies with the runner after one job. It goes in via an
  # env file on this container's tmpfs, deleted as soon as docker has read it.
  envf=$(mktemp)
  printf 'ACTIONS_RUNNER_INPUT_JITCONFIG=%s\n' "$(jq -r .encoded_jit_config <<<"$resp")" > "$envf"
  local args=(run -d --name "$JOB_NAME" --label "gh-runner.prefix=${PREFIX}" --label "gh-runner.id=${rid}"
    --init --network "$NETWORK" --cpus "$CPUS" --memory "$MEMORY" --memory-swap "$MEMORY_SWAP"
    --pids-limit "$PIDS"
    # Checkout, job temp files, step secrets and /tmp live in RAM only.
    --tmpfs "/home/runner/_work:rw,nosuid,nodev,exec,size=${WORK_SIZE},uid=${RUNNER_UID},gid=${RUNNER_UID},mode=0755"
    --tmpfs "/tmp:rw,nosuid,nodev,exec,size=${TMP_SIZE},mode=1777"
    --log-driver json-file --log-opt max-size=5m --log-opt max-file=2
    --env-file "$envf")
  if [ "$NO_SUDO" = "1" ]; then args+=(--cap-drop ALL --security-opt no-new-privileges:true); fi
  for d in $DNS; do args+=(--dns "$d"); done
  if ! docker "${args[@]}" "$IMAGE" /home/runner/run.sh >/dev/null; then
    rm -f "$envf"
    gh_api DELETE "/repos/${REPO}/actions/runners/${rid}" >/dev/null || true
    warn "could not start the runner container"; return 1
  fi
  rm -f "$envf"
  ok "runner ${name} online, waiting for a job (labels: ${LABELS})"
  wait_job "$rid"; rc=$JOB_RC
  # Removing the container drops its writable layer and its tmpfs mounts (work dir, /tmp).
  docker rm -f "$JOB_NAME" >/dev/null 2>&1 || true
  if [ "$rc" = stale ]; then ok "runner ${name} replaced; container and RAM work dir removed"; return 0; fi
  if [ "$rc" != "0" ]; then
    warn "runner ${name} exited with code ${rc}; container removed"; return 1
  fi
  ok "runner ${name} finished one job; container and RAM work dir removed"
}

# ---------- main ----------
[ -n "$REPO" ] && [[ "$REPO" == */* ]] || fail "GH_RUNNER_REPO must be OWNER/REPO or https://github.com/OWNER/REPO"
if [ -n "$APP_ID" ]; then
  [ -r "$APP_KEY_FILE" ] || fail "GH_RUNNER_APP_ID is set but ${APP_KEY_FILE} is not readable"
else
  [ -r "$PAT_FILE" ] || fail "no credentials: set GH_RUNNER_APP_ID + ${APP_KEY_FILE}, or ${PAT_FILE}"
fi

case "${1:-run}" in
  check)
    token || fail "could not get a GitHub token"
    list=$(gh_api GET "/repos/${REPO}/actions/runners?per_page=100") || fail "cannot list runners on ${REPO}: the token needs Administration: Read and write on it (a classic PAT: the repo scope)"
    ok "GitHub access ok ($([ -n "$APP_ID" ] && echo "GitHub App" || echo "PAT")): ${REPO} has $(jq '.total_count' <<<"$list") runner(s)"
    docker version -f '{{.Server.Version}}' >/dev/null 2>&1 || fail "docker daemon not reachable through the socket"
    ok "docker socket ok"
    exit 0 ;;
  run) ;;
  *) fail "unknown command: $1 (use run or check)" ;;
esac

info "supervising ephemeral runners for ${REPO} (prefix ${PREFIX}, image ${IMAGE})"

# A job container left from before a supervisor restart (e.g. redeploy) keeps running. Watch it
# like our own (its runner id is on a label), so it is still replaced if it never reconnects.
if [ "$(docker inspect -f '{{.State.Running}}' "$JOB_NAME" 2>/dev/null)" = "true" ]; then
  rid=$(docker inspect -f '{{index .Config.Labels "gh-runner.id"}}' "$JOB_NAME" 2>/dev/null || true)
  if [[ "$rid" =~ ^[0-9]+$ ]]; then
    info "a runner container is already running; watching it"
    wait_job "$rid"
    if [ "$JOB_RC" = stale ]; then ok "old runner replaced"; fi
  else
    info "a runner container is already running; waiting for it to finish"
    docker wait "$JOB_NAME" >/dev/null 2>&1 || true
  fi
fi
docker rm -f "$JOB_NAME" >/dev/null 2>&1 || true

failures=0
while true; do
  if token && remove_stale && pull_image && run_one; then
    failures=0
  else
    failures=$((failures + 1))
    delay=$((10 * 2 ** (failures < 5 ? failures : 5)))   # 20s .. 320s
    warn "retrying in ${delay}s (failure ${failures})"
    sleep "$delay"
  fi
done

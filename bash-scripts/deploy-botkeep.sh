#!/bin/bash
# bash-scripts/deploy-botkeep.sh
# Upload a local folder to a Botkeep workload through the Developer API and optionally restart it.
#
# Usage:  deploy-botkeep.sh <folder>
#
# Environment:
#   BOTKEEP_API_KEY        (required) bearer key with files:write (+ power:write when restarting)
#   BOTKEEP_WORKLOAD_ID    target workload id; when unset, the workload whose name matches the
#                          folder name (case-insensitive) is looked up through the API
#   BOTKEEP_CREATE_IF_MISSING  create the workload (named after the folder) when none exists, default true
#   BOTKEEP_PLATFORM, _RUNTIME, _RUNTIME_VERSION, _START_COMMAND, _MEMORY_MB, _CPU_PERCENT,
#   _STORAGE_MB            settings for a newly created workload
#                          (general, nodejs, 22, npm install && npm start, 1024, 50, 4096)
#   BOTKEEP_API_URL       API base URL, default https://api.botkeep.cloud
#   BOTKEEP_REMOTE_DIR     remote directory to upload into, default /
#   BOTKEEP_RESTART        restart the workload after upload (true/false), default true
#   BOTKEEP_EXCLUDE        space-separated find -path globs to skip,
#                          default: "*/.git/* */node_modules/* */.github/* */.env */.env.*"
#
# Notes:
#   - Files are uploaded with overwrite=true; files that only exist remotely are left untouched.
#   - The API limits a file to ~4 MB and a batch to 4 files; batches are also capped by size here.
#   - The key is passed to curl through stdin, so it never shows up in the process list or logs.
#   - Only paths and status are printed, never file contents or the key.

set -euo pipefail

FOLDER="${1:-}"
API_URL="${BOTKEEP_API_URL:-https://api.botkeep.cloud}"
API_URL="${API_URL%/}"
REMOTE_DIR="${BOTKEEP_REMOTE_DIR:-/}"
RESTART="${BOTKEEP_RESTART:-true}"
EXCLUDE="${BOTKEEP_EXCLUDE:-*/.git/* */node_modules/* */.github/* */.env */.env.*}"

CREATE="${BOTKEEP_CREATE_IF_MISSING:-true}"
PLATFORM="${BOTKEEP_PLATFORM:-general}"
RUNTIME="${BOTKEEP_RUNTIME:-nodejs}"
RUNTIME_VERSION="${BOTKEEP_RUNTIME_VERSION:-22}"
START_COMMAND="${BOTKEEP_START_COMMAND:-npm install --omit=dev --omit=optional --no-audit --no-fund --cache /tmp/.npm && npm start}"
MEMORY_MB="${BOTKEEP_MEMORY_MB:-1024}"
CPU_PERCENT="${BOTKEEP_CPU_PERCENT:-50}"
STORAGE_MB="${BOTKEEP_STORAGE_MB:-4096}"
OP_TIMEOUT="${BOTKEEP_OP_TIMEOUT:-600}"

MAX_FILE_BYTES=4000000   # server cap is 5333336 base64 chars (~4,000,002 bytes)
MAX_BATCH_FILES=4
MAX_BATCH_BYTES=4000000

log() { echo "[*] $*"; }
ok()  { echo "[+] $*"; }
err() { echo "[x] $*" >&2; }
die() { err "$*"; exit 1; }

[ -n "$FOLDER" ] || die "Usage: $0 <folder>"
[ -d "$FOLDER" ] || die "Folder not found: $FOLDER"
[ -n "${BOTKEEP_API_KEY:-}" ] || die "BOTKEEP_API_KEY is not set"
for bin in curl jq base64 find; do
  command -v "$bin" >/dev/null 2>&1 || die "Missing required command: $bin"
done

FOLDER="$(cd "$FOLDER" && pwd)"
API_BASE="${API_URL}/api/v1/developer"
REMOTE_DIR="/${REMOTE_DIR#/}"; REMOTE_DIR="${REMOTE_DIR%/}"   # "" for root, "/x/y" otherwise

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

idem_key() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }   # 48 hex chars

# api METHOD URL [JSON_BODY_FILE] -> response body in $WORK/resp, prints HTTP status
api() {
  local method="$1" url="$2" body="${3:-}" args=()
  args=(-sS -o "$WORK/resp" -w '%{http_code}' -X "$method" "$url"
        -H "Idempotency-Key: $(idem_key)" -H 'Content-Type: application/json')
  [ -n "$body" ] && args+=(--data-binary "@$body")
  printf 'header = "Authorization: Bearer %s"\n' "$BOTKEEP_API_KEY" | curl -K - "${args[@]}"
}

# api_wait METHOD URL [JSON_BODY_FILE]: like api, but while a new workload is still installing
# (409 "Files are unavailable until installation is complete") wait and retry
api_wait() {
  local code deadline=$((SECONDS + OP_TIMEOUT))
  while :; do
    code="$(api "$@")" || return 1
    if [ "$code" = 409 ] && grep -qi 'installation' "$WORK/resp" && [ "$SECONDS" -lt "$deadline" ]; then
      log "Workload is still installing, waiting..." >&2; sleep 10; continue
    fi
    echo "$code"; return 0
  done
}


fail_resp() {
  err "$1 (HTTP $2): $(head -c 500 "$WORK/resp" 2>/dev/null)"
  exit 1
}

# ---- resolve workload (upsert: look up by name, create when missing) --------
name="$(basename "$FOLDER")"

# wait_op OPERATION_ID: poll until the operation finishes
wait_op() {
  local op="$1" status code deadline=$((SECONDS + OP_TIMEOUT))
  while :; do
    code="$(api GET "${API_BASE}/operations/${op}")" || die "curl failed polling operation $op"
    case "$code" in 2*) ;; *) fail_resp "Polling operation $op failed" "$code";; esac
    status="$(jq -r '(.status // .state // "unknown") | ascii_downcase' "$WORK/resp")"
    log "operation $op: $status"
    case "$status" in
      succeeded|success|completed|complete|done|ready) return 0;;
      failed|failure|error|cancelled|canceled) fail_resp "Operation $op $status" "$code";;
    esac
    [ "$SECONDS" -lt "$deadline" ] || die "Timed out waiting for operation $op"
    sleep 5
  done
}

# find_workload: print the id of the workload named $name (empty when none)
find_workload() {
  local cursor="" code next found
  while :; do
    code="$(api GET "${API_BASE}/workloads?limit=100${cursor:+&cursor=${cursor}}")" || die "curl failed listing workloads"
    case "$code" in 2*) ;; *) fail_resp "Listing workloads failed" "$code";; esac
    found="$(jq -r --arg n "$name" '
      (if type == "array" then . else (.items // .workloads // .data // .results // []) end)
      | map(select((.name // "") | ascii_downcase == ($n | ascii_downcase)))
      | .[0] | (.id // .workloadId // empty)' "$WORK/resp")"
    [ -z "$found" ] || { echo "$found"; return 0; }
    next="$(jq -r '(.nextCursor // .next_cursor // .cursor // empty) | tostring' "$WORK/resp" 2>/dev/null || true)"
    { [ -n "$next" ] && [ "$next" != "$cursor" ]; } || return 0
    cursor="$next"
  done
}


# ---- diagnose mode: print workload state/console/files, change nothing -----------
if [ "${BOTKEEP_DIAGNOSE:-false}" = "true" ]; then
  [ -n "${BOTKEEP_WORKLOAD_ID:-}" ] || BOTKEEP_WORKLOAD_ID="$(find_workload)"
  [ -n "$BOTKEEP_WORKLOAD_ID" ] || die "No workload named '$name' to diagnose"
  for ep in "" /console /logs /files /files/list /power /resources /stats /operations; do
    c="$(api GET "${API_BASE}/workloads/${BOTKEEP_WORKLOAD_ID}${ep}" || true)"
    log "GET workloads/<id>${ep}: HTTP $c"
    [[ "$c" == 2* ]] && head -c 2500 "$WORK/resp" | tr '\n' ' ' && echo
  done
  exit 0
fi

if [ -z "${BOTKEEP_WORKLOAD_ID:-}" ]; then
  BOTKEEP_WORKLOAD_ID="$(find_workload)"
  if [ -n "$BOTKEEP_WORKLOAD_ID" ]; then
    log "Found existing workload '$name'"
  elif [ "$CREATE" != "true" ]; then
    err "No Botkeep workload named '$name' found (BOTKEEP_CREATE_IF_MISSING=false); set BOTKEEP_WORKLOAD_ID"
    exit 3
  else
    log "Workload '$name' not found, creating it"
    # If the plan's disk quota is exceeded, retry with smaller storage limits
    created=false
    for sto in "$STORAGE_MB" 3072 2048 1536 1024 512; do
      [ "$sto" -le "$STORAGE_MB" ] || continue
      jq -n --arg name "$name" --arg platform "$PLATFORM" --arg runtime "$RUNTIME" \
        --arg rv "$RUNTIME_VERSION" --arg sc "$START_COMMAND" \
        --argjson mem "$MEMORY_MB" --argjson cpu "$CPU_PERCENT" --argjson sto "$sto" \
        '{name:$name, platform:$platform, runtime:$runtime, runtimeVersion:$rv,
          sourceType:"blank", startCommand:$sc,
          resources:{memoryLimitMb:$mem, cpuLimitPercent:$cpu, storageLimitMb:$sto}}' > "$WORK/create.json"
      code="$(api POST "${API_BASE}/workloads" "$WORK/create.json")" || die "curl failed creating workload"
      case "$code" in 2*) created=true; log "Created with ${sto} MB storage"; break;; esac
      log "Create with ${sto} MB storage failed (HTTP $code): $(head -c 300 "$WORK/resp")"
      grep -qi 'disk allocation' "$WORK/resp" || break   # only retry on disk quota rejections
    done
    [ "$created" = true ] || fail_resp "Creating workload failed" "$code"
    BOTKEEP_WORKLOAD_ID="$(jq -r '.id // .workloadId // .workload.id // .data.id // empty' "$WORK/resp")"
    op="$(jq -r '.operationId // .operation_id // .operation.id // empty' "$WORK/resp")"
    [ -z "$op" ] || wait_op "$op"
    [ -n "$BOTKEEP_WORKLOAD_ID" ] || BOTKEEP_WORKLOAD_ID="$(find_workload)"
    [ -n "$BOTKEEP_WORKLOAD_ID" ] || die "Created workload but could not resolve its id: $(head -c 300 "$WORK/resp")"
    ok "Created workload '$name'"
  fi
fi
WORKLOAD_URL="${API_BASE}/workloads/${BOTKEEP_WORKLOAD_ID}"


# wait_ready: block until the workload finished installing; retry a failed installation (max 2x)
wait_ready() {
  local deadline=$((SECONDS + OP_TIMEOUT)) retries=0 code state ready can err_msg
  while :; do
    code="$(api GET "$WORKLOAD_URL")" || die "curl failed reading workload"
    case "$code" in 2*) ;; *) fail_resp "Reading workload failed" "$code";; esac
    ready="$(jq -r '.installationReady // false' "$WORK/resp")"
    [ "$ready" = true ] && return 0
    state="$(jq -r '(.lifecycleState // .status // "unknown") | ascii_downcase' "$WORK/resp")"
    can="$(jq -r '.canRetryInstallation // false' "$WORK/resp")"
    err_msg="$(jq -r '.provisioningError // empty' "$WORK/resp")"
    if [ "$state" = failed ] || [ "$state" = error ]; then
      if [ "$can" = true ] && [ "$retries" -lt 2 ]; then
        retries=$((retries + 1)); log "Installation failed (${err_msg:-unknown}); retry $retries/2"
        echo '{"action":"retry"}' > "$WORK/retry.json"
        code="$(api POST "${WORKLOAD_URL}/actions" "$WORK/retry.json")" || die "curl failed on retry"
        case "$code" in 2*) ;; *) fail_resp "Retry installation failed" "$code";; esac
      else
        die "Workload installation failed: ${err_msg:-state $state}"
      fi
    else
      log "Waiting for installation (state: $state)"
    fi
    [ "$SECONDS" -lt "$deadline" ] || die "Timed out waiting for the workload to finish installing"
    sleep 10
  done
}

log "Waiting for the workload to be ready"
wait_ready

# ---- collect files ----------------------------------------------------------
find_args=(-type f)
for pat in $EXCLUDE; do find_args+=(-not -path "$pat"); done
(cd "$FOLDER" && find . "${find_args[@]}" -print0 | LC_ALL=C sort -z) > "$WORK/files.list"

total=$(tr -cd '\0' < "$WORK/files.list" | wc -c)
[ "$total" -gt 0 ] || die "No files to upload in $FOLDER"
log "Deploying $total file(s) from $FOLDER to workload '${BOTKEEP_WORKLOAD_ID}' (dir: ${REMOTE_DIR:-/})"

# ---- create folders (best effort; the API may also create parents on upload) -
declare -A seen_dirs=()
while IFS= read -r -d '' f; do
  d="$(dirname "${f#./}")"
  while [ "$d" != "." ] && [ -z "${seen_dirs[$d]:-}" ]; do
    seen_dirs[$d]=1; d="$(dirname "$d")"
  done
done < "$WORK/files.list"

dirs=()
[ -n "$REMOTE_DIR" ] && dirs+=("$REMOTE_DIR")
for d in "${!seen_dirs[@]}"; do [ "$d" = "." ] || dirs+=("${REMOTE_DIR}/$d"); done
if [ "${#dirs[@]}" -gt 0 ]; then
  while IFS= read -r d; do
    jq -n --arg p "$d" '{path:$p,type:"folder",createOnly:true}' > "$WORK/dir.json"
    code="$(api_wait PUT "${WORKLOAD_URL}/file" "$WORK/dir.json" || true)"
    case "$code" in 2*) ;; *) log "folder $d: HTTP $code (assuming it exists)";; esac
  done < <(printf '%s\n' "${dirs[@]}" | LC_ALL=C sort)
fi

# ---- upload in batches ------------------------------------------------------
batch_n=0; batch_bytes=0; sent=0; batch_no=0

flush() {
  [ "$batch_n" -gt 0 ] || return 0
  batch_no=$((batch_no + 1))
  jq -s '{files: .}' "$WORK"/obj_*.json > "$WORK/batch.json"
  local code; code="$(api_wait POST "${WORKLOAD_URL}/files/upload-batch" "$WORK/batch.json")" || die "curl failed on batch $batch_no"
  case "$code" in 2*) ;; *) fail_resp "Batch $batch_no upload failed" "$code";; esac
  sent=$((sent + batch_n)); ok "Uploaded $sent/$total"
  rm -f "$WORK"/obj_*.json "$WORK/batch.json"
  batch_n=0; batch_bytes=0
}

while IFS= read -r -d '' f; do
  rel="${f#./}"
  size=$(wc -c < "$FOLDER/$rel")
  [ "$size" -le "$MAX_FILE_BYTES" ] || die "File too large for the API (${size} bytes, max ${MAX_FILE_BYTES}): $rel"
  if [ "$batch_n" -ge "$MAX_BATCH_FILES" ] || [ $((batch_bytes + size)) -gt "$MAX_BATCH_BYTES" ]; then flush; fi
  base64 -w0 < "$FOLDER/$rel" > "$WORK/data.b64"
  jq -n --arg p "${REMOTE_DIR}/${rel}" --rawfile d "$WORK/data.b64" \
    '{path:$p,data:$d,overwrite:true}' > "$WORK/obj_$(printf '%06d' "$batch_n").json"
  batch_n=$((batch_n + 1)); batch_bytes=$((batch_bytes + size))
done < "$WORK/files.list"
flush

# ---- restart ----------------------------------------------------------------
if [ "$RESTART" = "true" ]; then
  log "Restarting workload"
  echo '{"action":"restart"}' > "$WORK/action.json"
  code="$(api POST "${WORKLOAD_URL}/actions" "$WORK/action.json")" || die "curl failed on restart"
  case "$code" in 2*) ok "Restart accepted (HTTP $code)";; *) fail_resp "Restart failed" "$code";; esac
fi

ok "Deploy complete"

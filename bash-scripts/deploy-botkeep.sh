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
#   BOTKEEP_API_URL        API base URL, default https://botkeep.cloud
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
API_URL="${BOTKEEP_API_URL:-https://botkeep.cloud}"
API_URL="${API_URL%/}"
REMOTE_DIR="${BOTKEEP_REMOTE_DIR:-/}"
RESTART="${BOTKEEP_RESTART:-true}"
EXCLUDE="${BOTKEEP_EXCLUDE:-*/.git/* */node_modules/* */.github/* */.env */.env.*}"

MAX_FILE_BYTES=4000000    # server cap is 5333336 base64 chars (~4,000,002 bytes)
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

fail_resp() {
  err "$1 (HTTP $2): $(head -c 500 "$WORK/resp" 2>/dev/null)"
  exit 1
}

# ---- resolve workload -------------------------------------------------------
if [ -z "${BOTKEEP_WORKLOAD_ID:-}" ]; then
  name="$(basename "$FOLDER")"
  code="$(api GET "${API_BASE}/workloads?limit=100")" || die "curl failed listing workloads"
  case "$code" in 2*) ;; *) fail_resp "Listing workloads failed" "$code";; esac
  BOTKEEP_WORKLOAD_ID="$(jq -r --arg n "$name" '
    (if type == "array" then . else (.items // .workloads // .data // []) end)
    | map(select((.name // "") | ascii_downcase == ($n | ascii_downcase)))
    | .[0].id // empty' "$WORK/resp")"
  if [ -z "$BOTKEEP_WORKLOAD_ID" ]; then
    err "No Botkeep workload named '$name' found; set BOTKEEP_WORKLOAD_ID"
    exit 3
  fi
  log "Resolved workload '$name'"
fi
WORKLOAD_URL="${API_BASE}/workloads/${BOTKEEP_WORKLOAD_ID}"

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
    code="$(api PUT "${WORKLOAD_URL}/file" "$WORK/dir.json" || true)"
    case "$code" in 2*) ;; *) log "folder $d: HTTP $code (assuming it exists)";; esac
  done < <(printf '%s\n' "${dirs[@]}" | LC_ALL=C sort)
fi

# ---- upload in batches ------------------------------------------------------
batch_n=0; batch_bytes=0; sent=0; batch_no=0

flush() {
  [ "$batch_n" -gt 0 ] || return 0
  batch_no=$((batch_no + 1))
  jq -s '{files: .}' "$WORK"/obj_*.json > "$WORK/batch.json"
  local code; code="$(api POST "${WORKLOAD_URL}/files/upload-batch" "$WORK/batch.json")" || die "curl failed on batch $batch_no"
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

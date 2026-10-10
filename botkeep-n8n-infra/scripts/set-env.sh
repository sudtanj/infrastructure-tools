#!/bin/bash
# Push KEY=VALUE lines from an env file to a Botkeep workload as secret variables.
# Usage: BOTKEEP_API_KEY=... WORKLOAD_ID=... ./scripts/set-env.sh [.env]
set -euo pipefail

FILE="${1:-.env}"
API="${BOTKEEP_BASE_URL:-https://api.botkeep.cloud}/api/v1/developer"
: "${BOTKEEP_API_KEY:?set BOTKEEP_API_KEY}" "${WORKLOAD_ID:?set WORKLOAD_ID}"
[ -f "$FILE" ] || { echo "[x] $FILE not found" >&2; exit 1; }

while IFS= read -r line || [ -n "$line" ]; do
  [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
  key="${line%%=*}"; value="${line#*=}"
  [ -n "$value" ] || { echo "[!] skipping $key (empty)"; continue; }
  body=$(jq -n --arg k "$key" --arg v "$value" '{key:$k, value:$v, isSecret:true}')
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
    -H "Authorization: Bearer ${BOTKEEP_API_KEY}" \
    -H "Idempotency-Key: env$(openssl rand -hex 12)" \
    -H 'Content-Type: application/json' -d "$body" \
    "${API}/workloads/${WORKLOAD_ID}/environment")
  echo "[$([[ $code =~ ^2 ]] && echo + || echo x)] $key -> HTTP $code"
done < "$FILE"

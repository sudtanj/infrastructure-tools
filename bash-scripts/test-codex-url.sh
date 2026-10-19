#!/bin/bash
# bash-scripts/test-codex-url.sh
# Runs ON the VM via IAP SSH. Read-only: changes nothing, only tests whether CODEX_BASE_URL works
# from the VM, step by step, so a failing Codex in paseo-lite shows where it breaks:
#   1. name resolution        (MagicDNS names fail behind DNS64)
#   2. route                  (via tailscale0? a subnet IP needs an approved + accepted route)
#   3. tailnet path           (tailscale ping: WireGuard path to the peer, ignores the ACL)
#   4. TCP connect            (ACL / peer firewall / listen address)
#   5. GET  <base>/models     (with CODEX_API_KEY; lists whether CODEX_MODEL is served)
#   6. POST <base>/responses  (a tiny real request with CODEX_MODEL: what Codex actually calls)
#   7. the same GET from inside the paseo-lite container, when it runs (its DNS can differ)
#
# Env: CODEX_BASE_URL (required, else skipped), CODEX_API_KEY, CODEX_MODEL (optional).
# Secrets are never printed: the key goes to curl on stdin (curl -K -), so it is not in ps
# either, and only the URL's host and port are logged.
# Exit 0 when the endpoint answers the Responses call (or /models when CODEX_MODEL is unset), 1 otherwise.

set -uo pipefail

INIT_DEBUG="${INIT_DEBUG:-1}"
CODEX_BASE_URL="${CODEX_BASE_URL:-}"
CODEX_API_KEY="${CODEX_API_KEY:-}"
CODEX_MODEL="${CODEX_MODEL:-}"
CONTAINER_NAME="${CONTAINER_NAME:-paseo-lite}"

ok()   { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
bad()  { echo "[x] $*" >&2; FAILED=1; }
dbg()  { [ "$INIT_DEBUG" = "1" ] && echo "[d] $*" || true; }
redact() {
  local t
  t=$(cat)
  if [ -n "$CODEX_API_KEY" ]; then t="${t//"$CODEX_API_KEY"/***}"; fi
  printf '%s' "$t"
}
# curl with the key on stdin. Usage: kcurl <curl args...>
kcurl() {
  { [ -n "$CODEX_API_KEY" ] && printf 'header = "Authorization: Bearer %s"\n' "$CODEX_API_KEY"; true; } \
    | curl -K - "$@"
}
curl_why() {
  case "$1" in
    6)  echo "name does not resolve" ;;
    7)  echo "connection refused (nothing listening on that address and port?)" ;;
    28) echo "timed out (not routed, or dropped by the tailnet ACL / peer firewall)" ;;
    35|60) echo "TLS error (curl exit $1)" ;;
    *)  echo "curl exit $1" ;;
  esac
}
# First "message" field of a JSON error body, shortened and redacted.
err_msg() { grep -oE '"message"[[:space:]]*:[[:space:]]*"[^"]{0,200}' "$1" 2>/dev/null | head -n1 | sed -E 's/^"message"[[:space:]]*:[[:space:]]*"//' | redact; }

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -z "$CODEX_BASE_URL" ]; then
  warn "CODEX_BASE_URL is not set: nothing to test (skipped)"
  exit 0
fi
command -v curl >/dev/null 2>&1 || { echo "[x] curl not found on the VM" >&2; exit 1; }

BASE="${CODEX_BASE_URL%/}"
if [[ "$BASE" =~ ^(https?)://([^@/]*@)?([^/:?]+)(:([0-9]+))? ]]; then
  SCHEME="${BASH_REMATCH[1]}"; HOST="${BASH_REMATCH[3]}"; PORT="${BASH_REMATCH[5]}"
else
  echo "[x] CODEX_BASE_URL is not an http(s):// URL" >&2
  exit 1
fi
[ -z "$PORT" ] && { [ "$SCHEME" = "https" ] && PORT=443 || PORT=80; }
echo "[*] testing CODEX_BASE_URL (${SCHEME}://${HOST}:${PORT}), CODEX_API_KEY $([ -n "$CODEX_API_KEY" ] && echo set || echo unset), CODEX_MODEL ${CODEX_MODEL:-unset}"

TS=""
for c in "$(command -v tailscale 2>/dev/null)" /var/lib/docker/tailscale-bin/tailscale /var/lib/cloud/tailscale-bin/tailscale; do
  if [ -n "$c" ] && [ -x "$c" ]; then TS="$c"; break; fi
done

# --- 1. name resolution ---
IP="$HOST"
if ! [[ "$HOST" =~ ^[0-9.]+$ ]]; then
  IP=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -n "$IP" ]; then
    ok "1/7 ${HOST} resolves to ${IP}"
  else
    bad "1/7 ${HOST} does not resolve on the VM (MagicDNS names fail behind DNS64: use the 100.x or LAN IP)"
  fi
else
  ok "1/7 ${HOST} is an IP (no DNS needed)"
fi

# --- 2. route ---
VIA_TS=0
if [ -n "$IP" ]; then
  RT=$(ip -o route get "$IP" 2>/dev/null | head -n1)
  if printf '%s' "$RT" | grep -q ' dev tailscale0'; then
    VIA_TS=1
    ok "2/7 ${IP} is routed via tailscale0"
  else
    DEV=$(printf '%s' "$RT" | sed -nE 's/.* dev ([^ ]+).*/\1/p')
    case "$IP" in
      100.*|127.*) warn "2/7 ${IP} goes via ${DEV:-no route}" ;;
      *) warn "2/7 ${IP} goes via ${DEV:-no route}, not tailscale0: fine for a public endpoint; a home LAN IP needs its subnet route advertised, approved and accepted (init-tailscale.sh)" ;;
    esac
  fi
fi

# --- 3. tailnet path ---
if [ -n "$TS" ] && [ "$VIA_TS" = "1" ]; then
  if [[ "$IP" == 100.* ]]; then
    if PING_OUT=$(timeout 15 "$TS" ping -c 3 --timeout 4s "$IP" 2>&1); then
      ok "3/7 tailscale ping ${IP}: $(printf '%s' "$PING_OUT" | tail -n1)"
    else
      bad "3/7 tailscale ping ${IP} failed: no WireGuard path (peer offline, or UDP/DERP blocked)"
    fi
  else
    # Subnet IP: find which peer advertises it and check that one is online.
    dbg "3/7 ${IP} is a subnet address; peers: $("$TS" status 2>/dev/null | awk 'NR>1 && $1 ~ /^100\./ {print $2 "=" $NF}' | paste -sd' ' -)"
    ok "3/7 ${IP} is behind a subnet router (route accepted)"
  fi
elif [ -z "$TS" ]; then
  warn "3/7 tailscale binary not found: skipping the tailnet check"
else
  dbg "3/7 not a tailnet address: skipped"
fi

# --- 4. TCP connect ---
if [ -n "$IP" ]; then
  if ( timeout 6 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$IP" "$PORT"; exit $? ) >/dev/null 2>&1; then
    ok "4/7 TCP ${IP}:${PORT} connects"
  else
    if [ "$VIA_TS" = "1" ]; then
      bad "4/7 TCP ${IP}:${PORT} fails: dropped by the tailnet ACL (tag:home -> ${IP}:${PORT}), the peer's firewall, or the service listens on 127.0.0.1 only (ZILONG_ROUTER_BIND)"
    else
      bad "4/7 TCP ${IP}:${PORT} fails"
    fi
  fi
fi

# --- 5. GET /models ---
MODELS_OK=0
RC=0
CODE=$(kcurl -s -o "$TMP/models" -m 15 -w '%{http_code}' "${BASE}/models" 2>/dev/null) || RC=$?
case "${CODE:-000}" in
  2??)
    MODELS_OK=1
    IDS=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$TMP/models" | sed -E 's/.*"([^"]+)"$/\1/')
    N=$(printf '%s' "$IDS" | grep -c . || true)
    ok "5/7 GET /models: HTTP ${CODE}, ${N} model(s)"
    dbg "models: $(printf '%s' "$IDS" | head -n 20 | paste -sd' ' -)"
    if [ -n "$CODEX_MODEL" ] && [ "$N" -gt 0 ]; then
      if printf '%s\n' "$IDS" | grep -qxF "$CODEX_MODEL"; then
        ok "5/7 CODEX_MODEL ${CODEX_MODEL} is listed"
      else
        warn "5/7 CODEX_MODEL ${CODEX_MODEL} is not in /models (a router may still map it)"
      fi
    fi ;;
  401|403) bad "5/7 GET /models: HTTP ${CODE}, the endpoint rejects CODEX_API_KEY: $(err_msg "$TMP/models")" ;;
  000)     bad "5/7 GET /models: no answer, $(curl_why "$RC")" ;;
  *)       warn "5/7 GET /models: HTTP ${CODE} (the endpoint answers but has no /models): $(err_msg "$TMP/models")" ;;
esac

# --- 6. POST /responses (what Codex calls) ---
RESP_OK=0
if [ -n "$CODEX_MODEL" ]; then
  MODEL_JSON=$(printf '%s' "$CODEX_MODEL" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"model":"%s","input":"Reply with the single word OK.","max_output_tokens":16,"stream":false}' "$MODEL_JSON" > "$TMP/req"
  RC=0
  T0=$(date +%s)
  CODE=$(kcurl -s -o "$TMP/resp" -m 90 -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary @"$TMP/req" "${BASE}/responses" 2>/dev/null) || RC=$?
  DT=$(( $(date +%s) - T0 ))
  case "${CODE:-000}" in
    2??)
      RESP_OK=1
      TEXT=$(grep -oE '"text"[[:space:]]*:[[:space:]]*"[^"]{0,60}' "$TMP/resp" | head -n1 | sed -E 's/^"text"[[:space:]]*:[[:space:]]*"//' | redact)
      ok "6/7 POST /responses with ${CODEX_MODEL}: HTTP ${CODE} in ${DT}s${TEXT:+, reply: ${TEXT}}" ;;
    000) bad "6/7 POST /responses: no answer after ${DT}s, $(curl_why "$RC")" ;;
    404) bad "6/7 POST /responses: HTTP 404, the endpoint has no Responses API (Codex needs it, chat/completions is not enough): $(err_msg "$TMP/resp")" ;;
    *)   bad "6/7 POST /responses with ${CODEX_MODEL}: HTTP ${CODE}: $(err_msg "$TMP/resp")" ;;
  esac
else
  warn "6/7 CODEX_MODEL is not set: skipping the Responses call"
fi

# --- 7. from inside the container ---
if command -v docker >/dev/null 2>&1 && [ "$(timeout 10 docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
  if timeout 10 docker exec "$CONTAINER_NAME" sh -c 'command -v curl' >/dev/null 2>&1; then
    RC=0
    CODE=$({ [ -n "$CODEX_API_KEY" ] && printf 'header = "Authorization: Bearer %s"\n' "$CODEX_API_KEY"; true; } \
      | timeout 30 docker exec -i "$CONTAINER_NAME" curl -s -o /dev/null -m 15 -w '%{http_code}' -K - "${BASE}/models" 2>/dev/null) || RC=$?
    case "${CODE:-000}" in
      000) bad "7/7 inside ${CONTAINER_NAME}: no answer, $(curl_why "$RC") (the container's DNS differs from the host when DNS64 is on)" ;;
      *)   ok "7/7 inside ${CONTAINER_NAME}: GET /models answers (HTTP ${CODE})" ;;
    esac
  else
    dbg "7/7 ${CONTAINER_NAME} has no curl: skipped"
  fi
else
  dbg "7/7 ${CONTAINER_NAME} is not running: skipped"
fi

if [ -n "$CODEX_MODEL" ]; then PASS="$RESP_OK"; else PASS="$MODELS_OK"; fi
if [ "$PASS" = "1" ] && [ "$FAILED" = "0" ]; then
  ok "CODEX_BASE_URL works from the VM"
  exit 0
fi
if [ "$PASS" = "1" ]; then
  warn "CODEX_BASE_URL answers, but some checks above failed"
  exit 0
fi
echo "[x] CODEX_BASE_URL does not work from the VM: see the first failing step above" >&2
exit 1

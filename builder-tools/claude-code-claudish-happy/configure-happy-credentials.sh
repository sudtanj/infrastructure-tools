#!/usr/bin/env bash
set -euo pipefail

# Pre-seeds Happy's pairing credentials from an env var, so a fresh
# container doesn't have to go through the interactive QR-code/link flow
# every time (e.g. headless deploys, CI, or just a docker-compose.yml you
# don't want to babysit).
#
# Happy itself has no env var for this - it only ever reads
# ~/.happy/access.key (HAPPY_HOME_DIR/access.key), a small JSON file written
# once you approve the QR/link pairing from the phone or web app. This
# script just writes that same file from HAPPY_CREDENTIALS_B64 (its content,
# base64-encoded, to survive .env / YAML unscathed) if the file doesn't
# already exist.
#
# How to get the value the FIRST time (one-off, interactive):
#   docker compose run --rm agent happy claude
#   # complete the QR/link pairing, then Ctrl-C out once you see your prompt
#   docker compose run --rm agent bash -c 'base64 -w0 ~/.happy/access.key'
#   # put the output in .env as HAPPY_CREDENTIALS_B64=<value>
#
# Safe to run on every container start: it never overwrites an existing
# access.key (e.g. from the happy-config volume, or a previous pairing in
# this same run), so once paired, this becomes a no-op.

HAPPY_HOME="${HAPPY_HOME_DIR:-$HOME/.happy}"
CREDENTIALS_FILE="${HAPPY_HOME}/access.key"

[ -z "${HAPPY_CREDENTIALS_B64:-}" ] && exit 0
[ -f "$CREDENTIALS_FILE" ] && exit 0

decoded=$(printf '%s' "$HAPPY_CREDENTIALS_B64" | base64 -d 2>/dev/null) || {
    echo "warning: HAPPY_CREDENTIALS_B64 is not valid base64; ignoring it (Happy will fall back to interactive pairing)." >&2
    exit 0
}

if ! jq -e '.token and (.secret or .encryption)' >/dev/null 2>&1 <<<"$decoded"; then
    echo "warning: HAPPY_CREDENTIALS_B64 did not decode to a valid Happy credentials file; ignoring it (Happy will fall back to interactive pairing)." >&2
    exit 0
fi

mkdir -p "$HAPPY_HOME"
printf '%s' "$decoded" > "$CREDENTIALS_FILE"
chmod 600 "$CREDENTIALS_FILE"

#!/usr/bin/env bash
set -euo pipefail

# Registers a custom OpenAI-Responses-API-compatible endpoint with Codex
# CLI, from plain env vars, so users don't have to hand-write
# ~/.codex/config.toml.
#
# Codex CLI's own BYOK mechanism (see its config docs) is a
# [model_providers.<name>] table in ~/.codex/config.toml: a base_url, an
# env_key naming the environment variable that holds the API key (the key
# ITSELF never has to be written to the file - Codex reads it from the
# named env var at request time), and a wire_api. As of the Codex version
# this image installs, wire_api only supports "responses" (the
# /v1/responses format) - the older/more common "chat" (/v1/chat/completions)
# wire format some OpenAI-compatible gateways speak was removed upstream.
# Point CODEX_BASE_URL at an endpoint that actually speaks the Responses
# API, or this will fail at request time even though Codex starts fine.
#
# Env vars:
#   CODEX_BASE_URL  - the custom endpoint's base URL. Required to do
#                      anything here; if unset, this is a no-op and Codex
#                      uses its normal built-in OpenAI provider (needs a
#                      real OPENAI_API_KEY).
#   CODEX_API_KEY   - optional. If set, the provider is configured with
#                      env_key = "CODEX_API_KEY" so Codex reads the key
#                      from that env var at request time. If unset, no
#                      env_key is configured at all (for a local/trusted
#                      gateway that needs no auth header).
#   CODEX_MODEL     - optional. Sets the top-level `model` Codex uses by
#                      default.
#
# Idempotent and safe to run on every container start, even with a
# persisted codex-config volume: the managed block below is delimited by
# markers and fully replaced on each run; everything else in config.toml
# (anything you or Codex itself added outside those markers) is left alone.

CONFIG_DIR="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
MARKER_BEGIN="# >>> claude-code-claudish-happy: managed custom provider (do not edit inside) >>>"
MARKER_END="# <<< claude-code-claudish-happy: managed custom provider <<<"

[ -z "${CODEX_BASE_URL:-}" ] && exit 0

mkdir -p "$CONFIG_DIR"

# Strip any previously-written managed block, keep everything else as-is.
if [ -f "$CONFIG_FILE" ]; then
    awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip != 1 { print }
    ' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
else
    : > "${CONFIG_FILE}.tmp"
fi

{
    echo ""
    echo "$MARKER_BEGIN"
    echo "model_provider = \"custom\""
    if [ -n "${CODEX_MODEL:-}" ]; then
        printf 'model = "%s"\n' "$CODEX_MODEL"
    fi
    echo ""
    echo "[model_providers.custom]"
    echo "name = \"Custom\""
    printf 'base_url = "%s"\n' "$CODEX_BASE_URL"
    if [ -n "${CODEX_API_KEY:-}" ]; then
        echo 'env_key = "CODEX_API_KEY"'
    fi
    echo 'wire_api = "responses"'
    echo "$MARKER_END"
} >> "${CONFIG_FILE}.tmp"

mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

#!/usr/bin/env bash
# Startup script for the Botkeep (Pterodactyl) server: fetches a prebuilt Rust LLM
# server (mistral.rs) and a small GGUF model on first run, then serves an
# OpenAI-compatible API on $SERVER_PORT. Nothing is compiled on the server.
set -euo pipefail

BIN="${BIN:-./mistralrs-server}"
MODEL_DIR="${MODEL_DIR:-./models}"
PORT="${SERVER_PORT:-8080}"

: "${MISTRALRS_URL:?Set MISTRALRS_URL to a prebuilt mistralrs-server binary (see README)}"
: "${MODEL_URL:?Set MODEL_URL to a .gguf file URL (see README)}"
MODEL_FILE="${MODEL_FILE:-$(basename "${MODEL_URL%%\?*}")}"

if [ ! -x "$BIN" ]; then
  echo "Downloading mistralrs-server..."
  curl -fL --retry 3 -o "$BIN" "$MISTRALRS_URL"
  chmod +x "$BIN"
fi

mkdir -p "$MODEL_DIR"
if [ ! -s "$MODEL_DIR/$MODEL_FILE" ]; then
  echo "Downloading model $MODEL_FILE..."
  curl -fL --retry 3 -o "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_URL"
  mv "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_DIR/$MODEL_FILE"
fi

# Flags differ between mistral.rs versions; check `./mistralrs-server --help` and adjust here.
exec "$BIN" --port "$PORT" gguf -m "$MODEL_DIR" -f "$MODEL_FILE"

#!/usr/bin/env bash
# Startup script for a Botkeep server: downloads a prebuilt llama.cpp `llama-server` and a small
# GGUF model on first run, then serves an OpenAI-compatible API on the port Botkeep assigns
# ($SERVER_PORT). Nothing is compiled on the server. Sized for ~512 MB of RAM.
set -euo pipefail

LLAMA_TAG="${LLAMA_TAG:-b11552}"
MODEL_URL="${MODEL_URL:-https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf}"
MODEL_FILE="${MODEL_FILE:-$(basename "${MODEL_URL%%\?*}")}"
MODEL_DIR="${MODEL_DIR:-./models}"
LLAMA_DIR="${LLAMA_DIR:-./llama}"
PORT="${SERVER_PORT:-${PORT:-8080}}"
CTX="${LLAMA_CTX:-1024}"          # context size; the KV cache grows with it
THREADS="${LLAMA_THREADS:-2}"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported CPU architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ ! -x "$LLAMA_DIR/llama-server" ]; then
  url="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_TAG}/llama-${LLAMA_TAG}-bin-ubuntu-${ARCH}.tar.gz"
  echo "Downloading llama.cpp ${LLAMA_TAG} (${ARCH})..."
  mkdir -p "$LLAMA_DIR"
  curl -fL --retry 3 "$url" | tar -xz -C "$LLAMA_DIR" --strip-components=1
fi

mkdir -p "$MODEL_DIR"
if [ ! -s "$MODEL_DIR/$MODEL_FILE" ]; then
  echo "Downloading model $MODEL_FILE..."
  curl -fL --retry 3 -o "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_URL"
  mv "$MODEL_DIR/$MODEL_FILE.part" "$MODEL_DIR/$MODEL_FILE"
fi

args=(-m "$MODEL_DIR/$MODEL_FILE" --host 0.0.0.0 --port "$PORT" -c "$CTX" -t "$THREADS" --parallel 1)
# Set LLAMA_API_KEY on the workload to require "Authorization: Bearer <key>"
[ -z "${LLAMA_API_KEY:-}" ] || args+=(--api-key "$LLAMA_API_KEY")

echo "Starting llama-server on port $PORT"
export LD_LIBRARY_PATH="$PWD/$LLAMA_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$LLAMA_DIR/llama-server" "${args[@]}"

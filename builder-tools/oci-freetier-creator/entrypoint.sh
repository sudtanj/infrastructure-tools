#!/bin/sh
set -eu

# Self-heal ownership of the persistent /app volume on every start - same
# class of bug already hit (and fixed) for claude-code-claudish-happy's
# ~/.claude/~/.codex/~/.happy and paseo-codex's ~/.codex/~/.config: a named
# volume can retain root ownership from an earlier run, and a Dockerfile
# chown only ever affects the image layer, never an already-existing volume
# mounted over that path at runtime. Cheap and idempotent.
if [ "$(id -u)" = "0" ]; then
    chown -R oci:oci /app
fi

# Everything generated at runtime (oci_config, the private key, an
# auto-generated SSH keypair if you don't supply one) lives under here so
# it's covered by the /app volume mount and survives restarts, instead of
# regenerating (and, for the SSH key, invalidating any instance already
# built with the old one) on every container start.
CONFIG_DIR="/app/.oci"
mkdir -p "$CONFIG_DIR"

# main.py reads OCI_CONFIG as a path to an oci-cli-style ini file - point
# it at a generated one unless you've mounted/set your own.
OCI_CONFIG_PATH="${OCI_CONFIG:-$CONFIG_DIR/config}"
OCI_KEY_PATH="$CONFIG_DIR/oci_api_private_key.pem"

# Accept the private key either as base64 (simplest to paste into a .env /
# compose environment: block without worrying about newlines) or as raw PEM
# text with literal "\n" sequences in place of real newlines (also
# .env-friendly - a real multi-line value doesn't survive KEY=VALUE .env
# parsing cleanly).
if [ -n "${OCI_PRIVATE_KEY_BASE64:-}" ]; then
    echo "$OCI_PRIVATE_KEY_BASE64" | base64 -d > "$OCI_KEY_PATH"
elif [ -n "${OCI_PRIVATE_KEY:-}" ]; then
    printf '%s' "$OCI_PRIVATE_KEY" | sed 's/\\n/\n/g' > "$OCI_KEY_PATH"
fi
[ -f "$OCI_KEY_PATH" ] && chmod 600 "$OCI_KEY_PATH"

# Generate oci_config's single [DEFAULT] section from individual env vars -
# only if we actually have credentials to write; otherwise leave
# OCI_CONFIG_PATH alone in case you mounted a ready-made file there
# yourself instead.
if [ -n "${OCI_USER_OCID:-}" ]; then
    cat > "$OCI_CONFIG_PATH" <<EOF
[DEFAULT]
user=$OCI_USER_OCID
fingerprint=${OCI_FINGERPRINT:-}
tenancy=${OCI_TENANCY_OCID:-}
region=${OCI_REGION:-}
key_file=$OCI_KEY_PATH
EOF
fi
export OCI_CONFIG="$OCI_CONFIG_PATH"

# SSH_AUTHORIZED_KEYS_FILE: main.py auto-generates a keypair at this path
# itself if nothing exists there yet, so this only needs handling if you
# want to supply your OWN public key instead (e.g. one you already use
# elsewhere) via SSH_PUBLIC_KEY.
SSH_KEY_PATH="${SSH_AUTHORIZED_KEYS_FILE:-$CONFIG_DIR/id_rsa.pub}"
if [ -n "${SSH_PUBLIC_KEY:-}" ] && [ ! -f "$SSH_KEY_PATH" ]; then
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_KEY_PATH"
fi
export SSH_AUTHORIZED_KEYS_FILE="$SSH_KEY_PATH"

if [ "$(id -u)" = "0" ]; then
    chown -R oci:oci "$CONFIG_DIR"
    exec su-exec oci python main.py "$@"
else
    exec python main.py "$@"
fi

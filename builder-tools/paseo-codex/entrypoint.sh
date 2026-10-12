#!/usr/bin/env bash
set -euo pipefail

# Thin wrapper around Paseo's own entrypoint (run via tini as PID 1).
# Generates the Codex BYOK config first, fixes ownership of persisted
# config dirs, wires up gh as a git credential helper, then hands off to
# Paseo's original entrypoint via `exec` (same tini wrapping, same
# root -> gosu-to-paseo privilege drop).
#
# Claude Code needs no generated config: ANTHROPIC_API_KEY /
# ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL / ANTHROPIC_MODEL are read
# natively from the environment, which Paseo's daemon inherits.

: "${HOME:=/home/paseo}"
: "${CODEX_HOME:=${HOME}/.codex}"
export HOME CODEX_HOME

/usr/local/bin/configure-codex-provider

# Everything above runs as root, so anything it (or a `docker exec`, which
# defaults to root) wrote may be root-owned and unwritable by the `paseo`
# user (uid 1000). Heal ownership on every start, but only touch files
# that are actually wrong: `find ! -user paseo` skips correct files, which
# avoids rewriting metadata on every small Claude session file on a slow
# disk. -h avoids following symlinks, -xdev stays within the volume.
if [ "$(id -u)" = "0" ]; then
    for p in "$CODEX_HOME" "$HOME/.config" "$HOME/.claude" "$HOME/.claude.json"; do
        [ -e "$p" ] || continue
        find "$p" -xdev ! -user paseo -exec chown -h paseo:paseo {} + 2>/dev/null || true
    done
fi

# If a GitHub token is set, register gh as the git credential helper so
# plain `git clone`/`git pull` of private repos works too. Only writes
# gitconfig; the token stays in the env and is re-read on each git call.
if [ "${GH_TOKEN:-${GITHUB_TOKEN:-}}" != "" ] && [ "$(id -u)" = "0" ]; then
    gosu paseo gh auth setup-git 2>/dev/null || true
fi

exec /usr/bin/tini -- /usr/local/bin/paseo-docker-entrypoint "$@"

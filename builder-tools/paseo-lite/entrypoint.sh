#!/usr/bin/env bash
set -euo pipefail

# Runs under tini as PID 1. Generates the Codex BYOK config, heals ownership
# of persisted config dirs, wires up gh as a git credential helper, then
# drops root -> paseo (uid 1000) and execs the paseo-lite daemon.
#
# Claude Code needs no generated config: ANTHROPIC_API_KEY /
# ANTHROPIC_AUTH_TOKEN / ANTHROPIC_BASE_URL / ANTHROPIC_MODEL /
# CLAUDE_CODE_OAUTH_TOKEN are read natively from the environment, which the
# daemon passes through to every claude process it starts.

: "${HOME:=/home/paseo}"
: "${CODEX_HOME:=${HOME}/.codex}"
export HOME CODEX_HOME

/usr/local/bin/configure-codex-provider

run_as_paseo() {
    if [ "$(id -u)" = "0" ]; then
        su-exec paseo "$@"
    else
        "$@"
    fi
}

if [ "$(id -u)" = "0" ]; then
    # Anything written as root (this script, or a `docker exec` which
    # defaults to root) would be unwritable by paseo. Only touch files that
    # are actually wrong, so a slow disk isn't rewritten on every start.
    for p in "$HOME" "$CODEX_HOME" "$HOME/.config" "$HOME/.claude" "$HOME/.claude.json" "$HOME/.paseo-lite"; do
        [ -e "$p" ] || continue
        find "$p" -xdev ! -user paseo -exec chown -h paseo:paseo {} + 2>/dev/null || true
    done
fi

# Codex reads API-key auth from ~/.codex/auth.json; seed it once from
# OPENAI_API_KEY so a plain env var is enough (skipped for BYOK endpoints,
# which use CODEX_BASE_URL/CODEX_API_KEY instead).
if [ -n "${OPENAI_API_KEY:-}" ] && [ -z "${CODEX_BASE_URL:-}" ] \
   && [ -x /usr/local/lib/agents/codex ] && [ ! -s "$CODEX_HOME/auth.json" ]; then
    printenv OPENAI_API_KEY | run_as_paseo /usr/local/lib/agents/codex login --with-api-key >/dev/null 2>&1 || true
fi

# With a GitHub token, register gh as git's credential helper so plain
# `git clone`/`git pull` of private repos works. The token stays in the env.
if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    run_as_paseo gh auth setup-git 2>/dev/null || true
fi

# Global git/gh identity from the container env (GH_USERNAME / GH_EMAIL, set
# from GitHub Actions secrets). Done on every start because the home dir is
# a volume that hides anything baked into the image.
if [ -n "${GH_USERNAME:-}" ] || [ -n "${GH_EMAIL:-}" ]; then
    if [ -n "${GH_USERNAME:-}" ]; then
        run_as_paseo git config --global user.name "$GH_USERNAME" || true
    fi
    # Without an explicit email fall back to GitHub's private noreply address.
    email="${GH_EMAIL:-${GH_USERNAME}@users.noreply.github.com}"
    run_as_paseo git config --global user.email "$email" || true
fi
if command -v gh >/dev/null 2>&1; then
    run_as_paseo gh config set git_protocol https 2>/dev/null || true
    run_as_paseo gh config set prompt disabled 2>/dev/null || true
fi

if [ "$(id -u)" = "0" ]; then
    exec su-exec paseo /usr/local/bin/paseo-lite "$@"
fi
exec /usr/local/bin/paseo-lite "$@"

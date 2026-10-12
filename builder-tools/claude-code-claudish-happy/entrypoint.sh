#!/usr/bin/env bash
set -euo pipefail

# Entry point for the claude-code-claudish-happy image.
#
# Usage:
#   docker run ... claude              # plain Claude Code (default)
#   docker run ... codex               # plain Codex CLI (BYOK via CODEX_BASE_URL)
#   docker run ... happy claude        # Claude Code wrapped by Happy (mobile/web control)
#   docker run ... happy codex         # Codex wrapped by Happy
#   docker run ... background happy claude
#   docker run ... background happy codex
#                                       # Runs the given command inside a
#                                       # detached tmux session (a real pty,
#                                       # so the wrapped CLI's UI works
#                                       # whether or not the container itself
#                                       # was started with -it), then keeps
#                                       # the container running indefinitely
#                                       # so you can connect from the Happy
#                                       # app later without an attached
#                                       # terminal. Run with `docker compose
#                                       # up -d` (not `run --rm`, which is
#                                       # for one-off foreground use). Peek
#                                       # at it locally any time with:
#                                       #   docker exec -it <container> tmux attach -t happy
#                                       # (Ctrl-b d to detach without
#                                       # stopping it.) Pair Happy once,
#                                       # interactively, BEFORE going this
#                                       # route - see HAPPY_CREDENTIALS_B64
#                                       # below; an unpaired background run
#                                       # exits almost immediately after
#                                       # printing the pairing QR/link into
#                                       # a pane nobody's watching.
#   docker run ... bash                # drop into a shell with all CLIs on PATH
#
# Before exec'ing the requested CLI, this checks that the environment
# variables that CLI needs were actually supplied (e.g. via `environment:`
# in docker-compose.yml or `docker run -e ...`), and fails fast with a clear
# message instead of letting the CLI hang on a login prompt or die deep in
# its own startup code.
#
# For `codex` / `happy codex`, it also registers a custom
# OpenAI-Responses-API-compatible endpoint given via CODEX_BASE_URL (+
# optional CODEX_API_KEY / CODEX_MODEL) in ~/.codex/config.toml - see
# configure-codex-provider.sh and .env.example.
#
# For `happy` / `happy codex`, it pre-seeds Happy's pairing credentials
# from HAPPY_CREDENTIALS_B64 if set (see configure-happy-credentials.sh),
# then - if there's still no valid Happy credential - runs `happy auth
# login` (Happy's own pairing-only subcommand) BEFORE touching Claude Code
# or Codex at all, so a fresh/unpaired container never launches a real
# session it can't actually hand off to Happy.

PLACEHOLDER="sk-ant-api03-placeholder"

# Named volumes for ~/.claude, ~/.codex, and ~/.happy can end up owned by
# someone other than the agent user - e.g. Docker initializes a FRESH named
# volume by copying in the image path's own ownership, but a volume that
# already existed (from an older image build, or touched by a different
# UID) keeps whatever ownership it already had. The Dockerfile's own
# `chown` at build time only ever affects the image layer, not a volume
# mounted over that path at runtime - so a stale/pre-existing volume can
# silently wedge every CLI with "EACCES: permission denied" on first
# write. Fix it defensively on every start via the agent user's
# passwordless sudo; cheap, idempotent, and makes this self-healing
# instead of requiring a manual `docker exec ... chown`.
for _dir in "$HOME/.claude" "$HOME/.codex" "$HOME/.happy"; do
    sudo mkdir -p "$_dir"
    sudo chown -R "$(id -un):$(id -gn)" "$_dir"
done
unset _dir

die() {
    echo "" >&2
    echo "error: $1" >&2
    echo "" >&2
    exit 1
}

is_set() {
    # true if the named env var is set and non-empty
    local name="$1"
    [ -n "${!name:-}" ]
}

require_one_of() {
    # require_one_of "PURPOSE" VAR1 VAR2 ...
    local purpose="$1"; shift
    for var in "$@"; do
        if is_set "$var"; then
            return 0
        fi
    done
    die "$purpose requires one of the following environment variables to be set: $*
Set it in your docker-compose.yml 'environment:' block (or -e on 'docker run'). See .env.example."
}

require_anthropic_key() {
    if ! is_set ANTHROPIC_API_KEY || [ "${ANTHROPIC_API_KEY}" = "${PLACEHOLDER}" ]; then
        die "claude requires a real ANTHROPIC_API_KEY (the image only ships a placeholder to suppress the login dialog).
Set ANTHROPIC_API_KEY in your docker-compose.yml 'environment:' block. See .env.example."
    fi
}

# If there's no valid Happy credential yet (after trying to seed one from
# HAPPY_CREDENTIALS_B64), pair NOW via `happy auth login` - Happy's own
# pairing-only subcommand, which never touches Claude Code or Codex - then
# print the resulting credential and STOP, instead of continuing into a
# real session this same run. That keeps a fresh/unpaired container from
# launching a session it can't actually hand off to Happy, and gives the
# user a copy-pasteable value for next time.
ensure_happy_authenticated() {
    configure-happy-credentials

    local happy_home="${HAPPY_HOME_DIR:-$HOME/.happy}"
    local credentials_file="${happy_home}/access.key"
    [ -f "$credentials_file" ] && return 0

    echo "" >&2
    echo "[entrypoint] No Happy credentials found - pairing now (Claude Code/Codex will NOT start this run)." >&2
    echo "[entrypoint] Scan the QR code / open the link below, then approve the session." >&2
    echo "" >&2

    if ! happy auth login || [ ! -f "$credentials_file" ]; then
        die "Happy authentication failed or was cancelled - nothing was started. Re-run to try again."
    fi

    local token_b64
    token_b64=$(base64 -w0 "$credentials_file")

    echo "" >&2
    echo "======================================================================" >&2
    echo " Happy pairing complete. Copy the line below into your .env, then" >&2
    echo " re-run this same command - it will skip pairing and go straight" >&2
    echo " into your session from now on:" >&2
    echo "======================================================================" >&2
    echo "" >&2
    echo "HAPPY_CREDENTIALS_B64=${token_b64}" >&2
    echo "" >&2
    echo "======================================================================" >&2
    echo "" >&2
    exit 0
}

case "${1:-claude}" in
    claude)
        require_anthropic_key
        ;;
    codex)
        configure-codex-provider
        require_one_of "codex" OPENAI_API_KEY CODEX_BASE_URL
        ;;
    happy)
        ensure_happy_authenticated
        case "${2:-}" in
            codex)
                configure-codex-provider
                require_one_of "happy codex" OPENAI_API_KEY CODEX_BASE_URL
                ;;
            claude|*)
                require_anthropic_key
                ;;
        esac
        ;;
    background)
        shift
        [ "$#" -eq 0 ] && die "background requires a command to run, e.g.: background happy claude"

        SESSION_NAME="happy"
        echo "" >&2
        echo "[entrypoint] Starting '$*' in the background (tmux session '${SESSION_NAME}')." >&2
        echo "[entrypoint] Peek at it any time with: docker exec -it <container> tmux attach -t ${SESSION_NAME}" >&2
        echo "[entrypoint] (Ctrl-b d to detach without stopping it.)" >&2
        echo "" >&2

        # Re-invokes this SAME script with the given command, so all the
        # usual env checks / Happy auth / Codex provider setup above still
        # run - just now inside a tmux pty instead of directly as PID 1.
        # (tmux's server only stays up once a session exists, so this has
        # to come before any `tmux set-option -g` - that alone doesn't
        # reliably keep a fresh server alive.)
        tmux new-session -d -s "$SESSION_NAME" -- /usr/local/bin/entrypoint.sh "$@"
        # remain-on-exit: if the wrapped command exits (pairing needed and
        # nobody's watching, a crash, ...) the pane's last screen stays
        # inspectable via `tmux attach` instead of vanishing.
        tmux set-option -t "$SESSION_NAME" remain-on-exit on

        # PID 1 for the life of the container: keeps it running (for
        # `docker compose up -d`) independent of whether the tmux session
        # inside is still alive.
        exec sleep infinity
        ;;
    *)
        # Anything else (bash, sh, a custom command, ...) - run as-is,
        # no env requirements enforced.
        ;;
esac

exec "$@"

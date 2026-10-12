# syntax=docker/dockerfile:1

ARG PASEO_VERSION=latest

# ---------- Stage 1: build everything that needs tooling ----------
FROM ghcr.io/getpaseo/paseo:${PASEO_VERSION} AS builder
USER root

ARG CLAUDE_CODE_VERSION=latest
ARG CODEX_VERSION=latest
ARG GH_VERSION=2.63.2
ARG TARGETARCH
# Set to "" to leave an agent CLI out of the image (saves disk, RAM, build time).
ARG INSTALL_CLAUDE=1
ARG INSTALL_CODEX=1

# Agent CLIs into an isolated prefix so we can copy just this directory
RUN --mount=type=cache,target=/root/.npm \
    mkdir -p /opt/agents \
 && pkgs="" \
 && { [ -z "${INSTALL_CLAUDE}" ] || pkgs="$pkgs @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"; } \
 && { [ -z "${INSTALL_CODEX}" ] || pkgs="$pkgs @openai/codex@${CODEX_VERSION}"; } \
 && { [ -z "$pkgs" ] || npm install -g --no-audit --no-fund --loglevel=error --prefix /opt/agents $pkgs; } \
 && find /opt/agents -type f \( -name "*.map" -o -name "*.md" \) -delete

# gh as a single static binary (no apt repo, no apt layers)
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH:-amd64}.tar.gz" \
    | tar -xz -C /tmp \
 && install -m 755 /tmp/gh_${GH_VERSION}_linux_${TARGETARCH:-amd64}/bin/gh /usr/local/bin/gh-bin

# ---------- Stage 2: runtime ----------
FROM ghcr.io/getpaseo/paseo:${PASEO_VERSION}
USER root

# Same base image => same Node ABI, so native deps copy over safely.
COPY --from=builder /opt/agents/ /usr/local/
COPY --from=builder /usr/local/bin/gh-bin /usr/local/bin/gh

# Low-priority launcher: agents get their own heap cap, lowest CPU priority,
# and idle I/O class, so the Paseo daemon (and its relay pings) always wins
# when the shared e2-micro core is contended.
COPY --chmod=755 <<'EOF' /usr/local/bin/lowprio
#!/bin/sh
export NODE_OPTIONS="--max-old-space-size=384"
real="$1"; shift
if command -v ionice >/dev/null 2>&1; then
  exec nice -n 19 ionice -c3 "$real" "$@"
fi
exec nice -n 19 "$real" "$@"
EOF

# Replace each agent CLI with a thin wrapper that goes through lowprio.
# mv keeps the relative npm symlink valid (same directory).
RUN for b in claude codex; do \
      [ -e /usr/local/bin/$b ] || continue; \
      mv /usr/local/bin/$b /usr/local/bin/$b-real; \
      printf '%s\n' '#!/bin/sh' \
        "exec /usr/local/bin/lowprio /usr/local/bin/$b-real \"\$@\"" \
        > /usr/local/bin/$b; \
      chmod 755 /usr/local/bin/$b; \
    done

# Paseo defaults: relay on, everything optional off, minimal logging/disk I/O.
COPY --chmod=644 <<'EOF' /usr/local/share/paseo/config.default.json
{
  "daemon": {
    "mcp": { "enabled": false, "injectIntoAgents": false },
    "relay": { "enabled": true },
    "browserTools": { "enabled": false }
  },
  "log": {
    "console": { "level": "warn" },
    "file": { "level": "warn", "rotate": { "maxSize": "5m", "maxFiles": 2 } }
  },
  "agents": {
    "catalogRefreshTimeoutMs": 30000,
    "metadataGeneration": {
      "providers": [
        { "provider": "claude", "model": "claude-haiku-4-5-20251001", "thinkingOptionId": "low" }
      ]
    },
    "providers": {
      "opencode": { "enabled": false },
      "copilot": { "enabled": false },
      "pi": { "enabled": false }
    }
  }
}
EOF

COPY --chmod=755 configure-codex-provider.sh /usr/local/bin/configure-codex-provider
COPY --chmod=755 entrypoint.sh /usr/local/bin/paseo-codex-entrypoint

# Daemon gets a small heap (agents override this in their wrapper).
# Raise to 320 if the daemon itself ever OOMs.
# Also silence Claude Code background work.
ENV NODE_OPTIONS=--max-old-space-size=256 \
    UV_THREADPOOL_SIZE=2 \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
    DISABLE_ERROR_REPORTING=1 \
    DISABLE_BUG_COMMAND=1 \
    DISABLE_COST_WARNINGS=1

# Stays root: Paseo's own entrypoint drops to `paseo` via gosu.
ENTRYPOINT ["/usr/local/bin/paseo-codex-entrypoint"]
CMD []

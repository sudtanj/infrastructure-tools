# syntax=docker/dockerfile:1

# paseo-lite: Rust Paseo daemon + native Claude Code CLI + native Codex CLI
# on Alpine. No Node.js anywhere in the final image. The daemon is a prebuilt
# static binary (no Rust toolchain in the build), so the image builds fast.

ARG ALPINE_VERSION=3.20

# ---------- Stage 1: fetch the prebuilt daemon + native agent CLIs + gh ----------
FROM alpine:${ALPINE_VERSION} AS agents
ARG TARGETARCH
# "stable", "latest" or an exact version, passed to Claude's official installer.
ARG CLAUDE_CODE_VERSION=latest
# "latest" or an exact Codex release (e.g. 0.46.0 -> tag rust-v0.46.0).
ARG CODEX_VERSION=latest
ARG GH_VERSION=2.63.2
# paseo-lite release asset (built by sudtanj/paseo-code-rust CI, static musl).
# "latest" is a rolling release of main; pin with a release tag if one exists.
ARG PASEO_LITE_RELEASE=latest
# Set to "" to leave an agent CLI out of the image (saves disk + build time).
ARG INSTALL_CLAUDE=1
ARG INSTALL_CODEX=1
# The native Claude binary needs libgcc/libstdc++ on musl to run its installer.
RUN apk add --no-cache bash curl ca-certificates libgcc libstdc++ ripgrep
# The download URL below never changes for a rolling release, so the layer
# cache would keep an old daemon forever. ADD re-fetches this checksum on
# every build: a new release changes it and invalidates the download.
ADD https://github.com/sudtanj/paseo-code-rust/releases/download/${PASEO_LITE_RELEASE}/paseo-lite-x86_64-linux-musl.sha256 /tmp/paseo-lite.sha256
RUN mkdir -p /out \
 && curl -fsSL -o /out/paseo-lite "https://github.com/sudtanj/paseo-code-rust/releases/download/${PASEO_LITE_RELEASE}/paseo-lite-x86_64-linux-musl" \
 && echo "$(cut -d' ' -f1 /tmp/paseo-lite.sha256)  /out/paseo-lite" | sha256sum -c - \
 && chmod 755 /out/paseo-lite \
 && case "${TARGETARCH:-amd64}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && if [ -n "${INSTALL_CLAUDE}" ]; then \
      curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" \
      && cp -L /root/.local/bin/claude /out/claude; \
    fi \
 && if [ -n "${INSTALL_CODEX}" ]; then \
      if [ "${CODEX_VERSION}" = "latest" ]; then base=https://github.com/openai/codex/releases/latest/download; \
      else base="https://github.com/openai/codex/releases/download/rust-v${CODEX_VERSION}"; fi \
      && curl -fsSL "${base}/codex-${arch}-unknown-linux-musl.tar.gz" | tar -xz -C /tmp \
      && install -m755 "/tmp/codex-${arch}-unknown-linux-musl" /out/codex; \
    fi \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH:-amd64}.tar.gz" \
    | tar -xz -C /tmp \
 && install -m755 "/tmp/gh_${GH_VERSION}_linux_${TARGETARCH:-amd64}/bin/gh" /out/gh

# ---------- Stage 2: runtime ----------
FROM alpine:${ALPINE_VERSION}

# What agents need to do real work: a shell, git (+ssh remotes), ripgrep for
# Claude's search tools, and the C++ runtime the native Claude binary links.
# tini reaps orphaned grandchildren; su-exec drops root -> paseo. docker-cli
# drives the host Docker when the deploy shares its socket (PASEO_DOCKER_SOCKET=1).
RUN apk add --no-cache bash git openssh-client ca-certificates libgcc libstdc++ ripgrep tini su-exec docker-cli docker-cli-compose \
 && adduser -D -u 1000 -h /home/paseo -s /bin/bash paseo \
 && mkdir -p /workspace && chown paseo:paseo /workspace

COPY --from=agents /out/paseo-lite /usr/local/bin/paseo-lite
COPY --from=agents /out/ /usr/local/lib/agents/
RUN rm -f /usr/local/lib/agents/paseo-lite

# Low-priority launcher: agents run at the lowest CPU priority (and idle I/O
# class when available), so the daemon and its relay pings always win when
# the shared e2-micro core is contended.
COPY --chmod=755 <<'EOF' /usr/local/bin/lowprio
#!/bin/sh
real="$1"; shift
if command -v ionice >/dev/null 2>&1; then
  exec nice -n 19 ionice -c3 "$real" "$@"
fi
exec nice -n 19 "$real" "$@"
EOF

RUN mv /usr/local/lib/agents/gh /usr/local/bin/gh \
 && for b in claude codex; do \
      [ -e /usr/local/lib/agents/$b ] || continue; \
      printf '%s\n' '#!/bin/sh' "exec /usr/local/bin/lowprio /usr/local/lib/agents/$b \"\$@\"" > /usr/local/bin/$b; \
      chmod 755 /usr/local/bin/$b; \
    done

COPY --chmod=755 configure-codex-provider.sh /usr/local/bin/configure-codex-provider
COPY --chmod=755 entrypoint.sh /usr/local/bin/paseo-lite-entrypoint

# Daemon defaults for a network-reachable container on a free-tier VM.
# Claude Code: use the system ripgrep (musl) and silence background work.
ENV HOME=/home/paseo \
    PASEO_LISTEN=0.0.0.0:6768 \
    PASEO_RELAY_ENABLED=true \
    PASEO_LOG_CONSOLE_LEVEL=warn \
    USE_BUILTIN_RIPGREP=0 \
    DISABLE_AUTOUPDATER=1 \
    DISABLE_TELEMETRY=1 \
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    DISABLE_NON_ESSENTIAL_MODEL_CALLS=1 \
    DISABLE_ERROR_REPORTING=1 \
    DISABLE_BUG_COMMAND=1 \
    DISABLE_COST_WARNINGS=1 \
    GH_PROMPT_DISABLED=1 \
    GH_NO_UPDATE_NOTIFIER=1

WORKDIR /workspace
EXPOSE 6768

# Stays root so the entrypoint can heal volume ownership, then drops to paseo.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/paseo-lite-entrypoint"]
CMD []

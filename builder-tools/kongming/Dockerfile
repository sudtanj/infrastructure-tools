# syntax=docker/dockerfile:1

# kongming (https://github.com/sudtanj/kongming)
#
# Small self-improving agentic AI daemon in one Rust binary: nanobot-style web
# UI, Telegram, remote MCP (token / OAuth, HTTP or SSE), agent roles with
# delegation, skills and memory. No local storage at all: every row lives on
# Turso, so the container runs with a read-only root and no volume.
#
# Same build shape as zilong-router/:
#
# 1. Source comes from git (this repo's workflow builds with context: ./<folder>).
#    KONGMING_REF pins what gets built: empty = main.
# 2. Compile on the BUILD platform, cross-compile to the TARGET platform with
#    Debian's cross gcc; only the tiny runtime stage is emulated.

ARG KONGMING_REPO=https://github.com/sudtanj/kongming
ARG KONGMING_REF=
ARG RUST_IMAGE=rust:1-bookworm
# distroless/cc: glibc + libgcc + CA certs, no shell, no package manager.
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian12:nonroot

FROM --platform=$BUILDPLATFORM ${RUST_IMAGE} AS builder

ARG KONGMING_REPO
ARG KONGMING_REF
ARG TARGETARCH
ARG BUILDARCH

# `ring` (rustls) has C/asm parts, so another architecture needs a C
# cross-compiler plus target headers (libc6-dev-*-cross is only a Recommends).
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) target="x86_64-unknown-linux-gnu";  cc="x86_64-linux-gnu-gcc"; \
             pkgs="gcc-x86-64-linux-gnu libc6-dev-amd64-cross" ;; \
      arm64) target="aarch64-unknown-linux-gnu"; cc="aarch64-linux-gnu-gcc"; \
             pkgs="gcc-aarch64-linux-gnu libc6-dev-arm64-cross" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${TARGETARCH}" != "${BUILDARCH}" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends ${pkgs}; \
      rm -rf /var/lib/apt/lists/*; \
    fi; \
    rustup target add "${target}"; \
    command -v "${cc}"; \
    printf '%s' "${target}" > /tmp/target; \
    printf '%s' "${cc}" > /tmp/cc

WORKDIR /src
# BuildKit git source: the ref is resolved on every build, so a new commit
# always rebuilds while unchanged layers stay cached.
ADD ${KONGMING_REPO}.git#${KONGMING_REF:-main} /src

RUN set -eux; \
    target="$(cat /tmp/target)"; \
    cc="$(cat /tmp/cc)"; \
    upper="$(echo "${target}" | tr 'a-z-' 'A-Z_')"; \
    export "CARGO_TARGET_${upper}_LINKER=${cc}"; \
    export "CC_$(echo "${target}" | tr '-' '_')=${cc}"; \
    if [ -f Cargo.lock ]; then locked="--locked"; else locked=""; fi; \
    cargo build --release ${locked} --target "${target}"; \
    install -m755 "target/${target}/release/kongming" /usr/local/bin/kongming

# Static BusyBox for kongming's `shell` tool: one ~1 MB binary plus applet links,
# so the distroless runtime gets sh, ls, grep, sed, awk, wget, nc, tar, ... and
# nothing else (kongming lets it read and use the network, not write files);
# `cdp` is kongming itself (its Chrome DevTools client, for a browser on the tailnet).
FROM busybox:1.38-musl AS busybox
RUN set -eux; \
    mkdir -p /opt/busybox/bin; \
    cp /bin/busybox /opt/busybox/busybox; \
    for applet in $(/bin/busybox --list); do ln -s ../busybox "/opt/busybox/bin/${applet}"; done; \
    ln -s /usr/local/bin/kongming /opt/busybox/bin/cdp; \
    /opt/busybox/bin/sh -c 'echo busybox ok'

FROM ${RUNTIME_IMAGE}

COPY --from=builder /usr/local/bin/kongming /usr/local/bin/kongming
COPY --from=busybox /opt/busybox /opt/busybox

ENV PORT=18800 \
    KONGMING_HOST=0.0.0.0 \
    KONGMING_WORKERS=1 \
    LOG_LEVEL=info

USER 65532:65532
EXPOSE 18800

# No HEALTHCHECK: distroless has no shell; GET /health is there for the init script.
ENTRYPOINT ["/usr/local/bin/kongming"]

# syntax=docker/dockerfile:1

# mini-router (https://github.com/sudtanj/mini-router)
#
# One OpenAI- and Anthropic-compatible endpoint over every LLM provider you
# have. Pools, spillover on any failure, and protocol translation in both
# directions. Configured entirely from environment variables - there is no
# config file - which is why this image mounts nothing and why every knob
# below is an `environment:` entry in the compose files next to this.
#
# Two things about this build are deliberate:
#
# 1. The source is fetched here rather than COPYed. This repo's workflow
#    builds each folder with `context: ./<folder>`, so the folder is the
#    whole build context - mini-router's source lives in its own repo and
#    has to come over the network. MINI_ROUTER_REF pins what gets built:
#    leave it empty for the repo's default branch (whatever that is named),
#    or set it to a tag for a reproducible image.
#
# 2. The compile runs on the BUILD platform and cross-compiles to the
#    TARGET platform. This repo builds linux/amd64 + linux/arm64 through
#    QEMU, and a Rust release build (LTO, one codegen unit) under emulation
#    takes tens of minutes. Cross-compiling keeps the arm64 image roughly
#    as cheap as the amd64 one. Only the tiny runtime stage is emulated.

ARG MINI_ROUTER_REPO=https://github.com/sudtanj/mini-router
# Empty means "the repository's default branch", which keeps this working
# regardless of whether that is called main, master or something else.
ARG MINI_ROUTER_REF=
ARG RUST_IMAGE=rust:1-bookworm
ARG RUNTIME_IMAGE=debian:bookworm-slim

FROM --platform=$BUILDPLATFORM ${RUST_IMAGE} AS builder

ARG MINI_ROUTER_REPO
ARG MINI_ROUTER_REF
ARG TARGETARCH
ARG BUILDARCH

# `ring` (rustls' crypto backend) carries C and assembly, so building for
# another architecture needs a C cross-compiler, not just the Rust std for
# the target. On its own architecture Debian's gcc already provides the
# triplet-prefixed name, so the cross packages are only fetched when the
# target actually differs from the build platform.
#
# The libc6-dev-*-cross package is listed explicitly and deliberately.
# `gcc-aarch64-linux-gnu` only *Recommends* it, so under
# --no-install-recommends the compiler arrives with no target headers at
# all and ring dies on `#include <stdlib.h>` with "compilation terminated".
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
RUN set -eux; \
    if [ -n "${MINI_ROUTER_REF}" ]; then \
      git clone --depth 1 --branch "${MINI_ROUTER_REF}" "${MINI_ROUTER_REPO}" .; \
    else \
      git clone --depth 1 "${MINI_ROUTER_REPO}" .; \
    fi; \
    git --no-pager log -1 --format='building mini-router %h (%cs) %d'

# --locked so the image is built against the committed Cargo.lock rather
# than whatever resolves on the day.
RUN set -eux; \
    target="$(cat /tmp/target)"; \
    cc="$(cat /tmp/cc)"; \
    upper="$(echo "${target}" | tr 'a-z-' 'A-Z_')"; \
    export "CARGO_TARGET_${upper}_LINKER=${cc}"; \
    # Underscores, not the dashed triple: `CC_x86_64-unknown-linux-gnu` is
    # not a legal shell variable name and `export` rejects it outright. The
    # `cc` crate looks up this spelling too.
    export "CC_$(echo "${target}" | tr '-' '_')=${cc}"; \
    cargo build --release --locked --target "${target}"; \
    install -m755 "target/${target}/release/mini-router" /usr/local/bin/mini-router

FROM ${RUNTIME_IMAGE}

# ca-certificates is the only runtime dependency: every provider API is
# https, and without the trust store every request fails at the handshake.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin minirouter

COPY --from=builder /usr/local/bin/mini-router /usr/local/bin/mini-router

USER 10001
EXPOSE 8080

# Inside a container, localhost is nobody.
ENV MINI_ROUTER_LISTEN=0.0.0.0:8080

# mini-router probes itself. `--healthcheck` opens a socket to its own
# /healthz and exits 0 or 1, which is why this image needs no shell tooling,
# no curl and no wget just to be health-checked. /healthz is unauthenticated
# on purpose, so this keeps working with MINI_ROUTER_REQUIRE_AUTH=true.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD ["/usr/local/bin/mini-router", "--healthcheck"]

ENTRYPOINT ["/usr/local/bin/mini-router"]
CMD []

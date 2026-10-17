# syntax=docker/dockerfile:1

# zilong-router (https://github.com/sudtanj/zilong-router)
#
# Rust port of 9router: one OpenAI/Anthropic-compatible endpoint over many
# providers, multi-account fallback, usage tracking and the 9router dashboard,
# in a single small binary. Same env variables and SQLite schema as 9router
# (PORT, DATA_DIR, INITIAL_PASSWORD, JWT_SECRET, ...), plus TURSO_* for an
# offsite database.
#
# Two things about this build are deliberate:
#
# 1. The source is fetched here rather than COPYed. This repo's workflow
#    builds each folder with `context: ./<folder>`, so zilong-router's source
#    comes over the network. ZILONG_ROUTER_REF pins what gets built: empty means
#    the default branch, or set a tag/branch for a reproducible image.
#
# 2. The compile runs on the BUILD platform and cross-compiles to the TARGET
#    platform. A release build (fat LTO, one codegen unit) under QEMU takes
#    tens of minutes; cross-compiling keeps arm64 as cheap as amd64. Only the
#    tiny runtime stage is emulated.

ARG ZILONG_ROUTER_REPO=https://github.com/sudtanj/zilong-router
ARG ZILONG_ROUTER_REF=
ARG RUST_IMAGE=rust:1-bookworm
# distroless/cc: glibc + libgcc + CA certificates and nothing else (~25 MB,
# no shell, no package manager). Runs as uid 65532.
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian12:nonroot

FROM --platform=$BUILDPLATFORM ${RUST_IMAGE} AS builder

ARG ZILONG_ROUTER_REPO
ARG ZILONG_ROUTER_REF
ARG TARGETARCH
ARG BUILDARCH

# `ring` (rustls) and the bundled SQLite are C, so another architecture needs
# a C cross-compiler plus target headers. libc6-dev-*-cross is listed
# explicitly: gcc-aarch64-linux-gnu only *Recommends* it, and under
# --no-install-recommends the compiler would arrive without <stdlib.h>.
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
# A BuildKit git source, not `RUN git clone`: BuildKit resolves the ref to a
# commit on every build and keys the cache on it, so a new commit always
# rebuilds. A RUN clone has a constant command line and stays cached forever.
ADD ${ZILONG_ROUTER_REPO}.git#${ZILONG_ROUTER_REF:-main} /src

# --locked: build against the committed Cargo.lock.
RUN set -eux; \
    target="$(cat /tmp/target)"; \
    cc="$(cat /tmp/cc)"; \
    upper="$(echo "${target}" | tr 'a-z-' 'A-Z_')"; \
    export "CARGO_TARGET_${upper}_LINKER=${cc}"; \
    # Underscores, not the dashed triple: `CC_x86_64-unknown-linux-gnu` is not
    # a legal shell variable name. The `cc` crate looks up this spelling too.
    export "CC_$(echo "${target}" | tr '-' '_')=${cc}"; \
    cargo build --release --locked --target "${target}"; \
    install -m755 "target/${target}/release/zilong-router" /usr/local/bin/zilong-router; \
    # Empty data dir owned by the runtime user, so a fresh named volume (or the
    # image layer itself) is writable without a shell in the final image.
    install -d -o 65532 -g 65532 /data

FROM ${RUNTIME_IMAGE}

COPY --from=builder /usr/local/bin/zilong-router /usr/local/bin/zilong-router
COPY --from=builder --chown=65532:65532 /data /data

# HOSTNAME is the bind address (9router's name for it). Docker sets HOSTNAME
# to the container id, so the image must override it.
ENV DATA_DIR=/data \
    HOSTNAME=0.0.0.0 \
    PORT=20128 \
    ZILONG_ROUTER_WORKERS=1

USER 65532:65532
EXPOSE 20128
VOLUME /data

# No HEALTHCHECK: distroless has no shell or curl, and a periodic probe costs
# CPU on a small board. The init script checks the container stays up.
ENTRYPOINT ["/usr/local/bin/zilong-router"]
CMD []

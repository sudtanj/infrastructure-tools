# syntax=docker/dockerfile:1

# dengai (https://github.com/sudtanj/dengai)
#
# Small Rust Steam bot for one account: card farming, key redeem, free-license
# auto-claim (PICS) and a bearer-token HTTP API. Built like zilong-router: the
# source is fetched by BuildKit (DENGAI_REF pins a tag/branch) and compiled on
# the BUILD platform, cross-compiling to the TARGET, so arm64 needs no QEMU
# for the Rust build.

ARG DENGAI_REPO=https://github.com/sudtanj/dengai
ARG DENGAI_REF=
ARG DENGAI_REVISION=unknown
ARG RUST_IMAGE=rust:1-bookworm
# distroless/cc: glibc + libgcc + CA certificates (needed for Steam's TLS) and
# nothing else. Runs as uid 65532.
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian12:nonroot

FROM --platform=$BUILDPLATFORM ${RUST_IMAGE} AS builder

ARG DENGAI_REPO
ARG DENGAI_REF
ARG TARGETARCH
ARG BUILDARCH

# aws-lc-rs (pulled in by steam-vent's reqwest) is C, so another architecture
# needs a C cross-compiler plus target headers.
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
# BuildKit git source: the ref resolves to a commit on every build, so a new
# commit always rebuilds (a RUN git clone would stay cached).
ADD ${DENGAI_REPO}.git#${DENGAI_REF:-main} /src

RUN set -eux; \
    target="$(cat /tmp/target)"; \
    cc="$(cat /tmp/cc)"; \
    upper="$(echo "${target}" | tr 'a-z-' 'A-Z_')"; \
    export "CARGO_TARGET_${upper}_LINKER=${cc}"; \
    export "CC_$(echo "${target}" | tr '-' '_')=${cc}"; \
    cargo build --release --locked --target "${target}"; \
    install -m755 "target/${target}/release/dengai" /usr/local/bin/dengai; \
    install -d -o 65532 -g 65532 /data

FROM ${RUNTIME_IMAGE}

ARG DENGAI_REVISION
LABEL org.opencontainers.image.source="https://github.com/sudtanj/dengai" \
      org.opencontainers.image.revision="${DENGAI_REVISION}"

COPY --from=builder /usr/local/bin/dengai /usr/local/bin/dengai
COPY --from=builder --chown=65532:65532 /data /data

# The API binds all interfaces inside the container; compose publishes it on
# the host's loopback only.
ENV DENGAI_DATA_DIR=/data \
    DENGAI_API_BIND=0.0.0.0:8737

# No HEALTHCHECK: distroless has no shell or curl, and dengai has no probe subcommand
# (only --help and --version). The deploy script polls docker state instead.
USER 65532:65532
EXPOSE 8737
VOLUME /data

ENTRYPOINT ["/usr/local/bin/dengai"]
CMD []

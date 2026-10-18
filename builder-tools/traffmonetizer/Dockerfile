# Traffmonetizer on distroless: the official client is a single static Rust
# (musl) binary on an empty image, run as root, with no CA bundle and no
# /etc/passwd. This moves it onto gcr.io/distroless/static (CA certs, tzdata,
# a nonroot user, still no shell) and runs it as uid 65532.
#
# Upstream has no multi-arch index: it pushes one tag per arch (`latest` for
# amd64, `arm64v8` for arm64), and labels every one of them linux/amd64. A
# plain `docker pull traffmonetizer/cli_v2` on an arm64 board therefore gets
# the x86 binary. Here both tags are pulled as the amd64 they claim to be,
# buildx picks the right one per target platform, and the ELF header is
# checked so a mislabeled upstream push fails the build, not the device.
ARG TM_TAG_AMD64=latest
ARG TM_TAG_ARM64=arm64v8

FROM --platform=linux/amd64 traffmonetizer/cli_v2:${TM_TAG_AMD64} AS upstream-amd64
FROM --platform=linux/amd64 traffmonetizer/cli_v2:${TM_TAG_ARM64} AS upstream-arm64
FROM upstream-${TARGETARCH} AS upstream

# Runs on the build host (no QEMU): ELF e_machine at offset 18 is 0x3e for
# x86_64 and 0xb7 for aarch64. The binary is never executed at build time;
# it connects out as soon as it starts.
FROM --platform=$BUILDPLATFORM busybox:1.38-musl AS check
ARG TARGETARCH
COPY --from=upstream /usr/local/bin/cli /cli
RUN case "$TARGETARCH" in \
      amd64) want=3e00 ;; \
      arm64) want=b700 ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    got="$(od -An -tx1 -j18 -N2 /cli | tr -d ' \n')"; \
    [ "$got" = "$want" ] \
      || { echo "upstream binary has e_machine ${got}, expected ${want} for ${TARGETARCH}" >&2; exit 1; }

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=check /cli /usr/local/bin/cli

# The client writes its device ID to $HOME/.config/traffmonetizer/
# (cli_device_ids.json). The compose files and init script mount a 1 MB tmpfs
# here, so it works on a read-only rootfs and nothing is kept: each new
# container is a new device.
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# The client runs on tokio, which reads this: one async worker thread instead
# of one per host core. All the work is network I/O and the container is
# capped well below one core anyway, so extra workers only add threads,
# stacks and context switches.
ENV TOKIO_WORKER_THREADS=1

ENTRYPOINT ["/usr/local/bin/cli"]

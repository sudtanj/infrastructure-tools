# Pawns (IPRoyal) on distroless: the official client is a single static Go
# binary on an empty image with only a CA bundle, run as root, with no
# /etc/passwd, tzdata or /tmp. This moves it onto gcr.io/distroless/static
# (CA certs, tzdata, a nonroot user, still no shell) and runs it as uid 65532.
# Upstream publishes a proper multi-arch index, so buildx picks the matching
# binary for each target platform.
FROM iproyal/pawns-cli:latest AS upstream

# Runs on the build host (no QEMU): ELF e_machine at offset 18 is 0x3e for
# x86_64 and 0xb7 for aarch64. The binary is never executed at build time;
# it connects out as soon as it starts.
FROM --platform=$BUILDPLATFORM busybox:1.37-musl AS check
ARG TARGETARCH
COPY --from=upstream /pawns-cli /pawns-cli
RUN case "$TARGETARCH" in \
      amd64) want=3e00 ;; \
      arm64) want=b700 ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    got="$(od -An -tx1 -j18 -N2 /pawns-cli | tr -d ' \n')"; \
    [ "$got" = "$want" ] \
      || { echo "upstream binary has e_machine ${got}, expected ${want} for ${TARGETARCH}" >&2; exit 1; }

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=check /pawns-cli /usr/local/bin/pawns-cli

# Nothing needs to be kept (the device ID is a flag), but the compose files
# and init script mount a 1 MB tmpfs here in case the client writes anything,
# so it works on a read-only rootfs.
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# The binary is Go 1.25+, which already sizes GOMAXPROCS from the container's
# CPU quota. GOMEMLIMIT makes the GC work harder as the heap nears 48 MiB,
# below the 64 MB container cap, instead of growing until the OOM killer
# steps in.
ENV GOMEMLIMIT=48MiB

# The client refuses to start until the terms of service are accepted.
ENTRYPOINT ["/usr/local/bin/pawns-cli", "-accept-tos"]

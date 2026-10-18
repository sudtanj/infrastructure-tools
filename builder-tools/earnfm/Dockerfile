# EarnFM on distroless: the official client is a static Go binary
# (CGO_ENABLED=0) on Alpine with a shell and apk, run as root. This moves it
# onto gcr.io/distroless/static (CA certs, tzdata, a nonroot user, no shell)
# and runs it as uid 65532. Upstream publishes a proper multi-arch index, so
# buildx picks the matching binary for each target platform.
FROM earnfm/earnfm-client:latest AS upstream

# Runs on the build host (no QEMU): ELF e_machine at offset 18 is 0x3e for
# x86_64 and 0xb7 for aarch64. The binary is never executed at build time;
# it connects out as soon as it starts.
FROM --platform=$BUILDPLATFORM busybox:1.38-musl AS check
ARG TARGETARCH
COPY --from=upstream /app/main /earnfm
RUN case "$TARGETARCH" in \
      amd64) want=3e00 ;; \
      arm64) want=b700 ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    got="$(od -An -tx1 -j18 -N2 /earnfm | tr -d ' \n')"; \
    [ "$got" = "$want" ] \
      || { echo "upstream binary has e_machine ${got}, expected ${want} for ${TARGETARCH}" >&2; exit 1; }

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=check /earnfm /usr/local/bin/earnfm

# The client keeps its state in EARNFM_DATA_DIR (default /var/lib/earnfm,
# which nonroot cannot write). Point it at the nonroot home; the compose files
# and init script mount a 1 MB tmpfs there, so it works on a read-only rootfs
# and nothing is kept: each new container is a new device.
ENV HOME=/home/nonroot \
    EARNFM_DATA_DIR=/home/nonroot
WORKDIR /home/nonroot

# The binary is built with Go 1.23, which sizes GOMAXPROCS from the host's
# cores, not the container's CPU quota (cgroup-aware defaults came in Go
# 1.25). Under a 0.25 CPU cap on a 4-core board that means 4 Ps fighting over
# a quarter core and getting throttled. GOMEMLIMIT makes the GC work harder
# as the heap nears 48 MiB, below the 64 MB container cap, instead of growing
# until the OOM killer steps in.
ENV GOMAXPROCS=1 \
    GOMEMLIMIT=48MiB

ENTRYPOINT ["/usr/local/bin/earnfm"]

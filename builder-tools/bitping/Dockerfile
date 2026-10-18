# Bitping on distroless: the official image is Alpine with a shell script as
# PID 1 that relaunches the client with growing delays (Docker's restart
# policy does that here), runs it as root, and lets it replace its own binary
# from releases.bitping.com. The client is a single static (musl) Rust
# binary, so it moves onto gcr.io/distroless/static as is and runs as uid
# 65532. Upstream publishes a proper multi-arch index, so buildx picks the
# matching binary for each target platform; copying it needs no QEMU.
FROM bitping/bitpingd:latest AS upstream

# Runs on the build host: ELF e_machine at offset 18 is 0x3e for x86_64 and
# 0xb7 for aarch64, and the binary must be static (no musl loader to load it
# on distroless). It is never executed at build time; it connects out as soon
# as it starts.
FROM --platform=$BUILDPLATFORM busybox:1.38-musl AS check
ARG TARGETARCH
COPY --from=upstream /app/bitpingd /bitpingd
RUN case "$TARGETARCH" in \
      amd64) want=3e00 ;; \
      arm64) want=b700 ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    got="$(od -An -tx1 -j18 -N2 /bitpingd | tr -d ' \n')"; \
    [ "$got" = "$want" ] \
      || { echo "upstream binary has e_machine ${got}, expected ${want} for ${TARGETARCH}" >&2; exit 1; }; \
    if grep -q '/lib/ld-' /bitpingd; then \
      echo "upstream binary is dynamically linked; distroless static cannot run it" >&2; exit 1; \
    fi

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=check /bitpingd /usr/local/bin/bitpingd

# The client keeps its login tokens and a SQLite database in ~/.bitpingd. The
# compose files and init script mount a small tmpfs on the home dir, so it
# works on a read-only rootfs and every new container is a new node.
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# With no arguments the client logs in from BITPING_API_KEY (or
# BITPING_EMAIL / BITPING_PASSWORD / BITPING_MFA) and starts the node.
ENTRYPOINT ["/usr/local/bin/bitpingd"]

# PacketStream on distroless: the official image is Debian bookworm with apt,
# run as root, and ships the 386, amd64, arm and arm64 clients in every
# platform image behind a shell launcher. The launcher sleeps 10 s on every
# start and, on aarch64, test-runs and then prefers the 32-bit ARMv6 client
# whenever the kernel can execute it. That build does TLS without the CPU's
# AES/SHA instructions, which makes it slow and stall-prone under a CPU cap.
#
# Here the binary for the target arch is picked at build time and run
# directly: no launcher, no sleep, no 32-bit fallback, nothing decided at
# runtime. Every platform image carries all four binaries, so the build
# platform's copy is used and no QEMU is needed.
FROM --platform=$BUILDPLATFORM packetstream/psclient:latest AS upstream

# Runs on the build host: ELF e_machine at offset 18 is 0x3e for x86_64 and
# 0xb7 for aarch64. The binary is never executed at build time; it connects
# out as soon as it starts.
FROM --platform=$BUILDPLATFORM busybox:1.37-musl AS check
ARG TARGETARCH
COPY --from=upstream /usr/local/bin/linux_${TARGETARCH}/psclient /psclient
RUN case "$TARGETARCH" in \
      amd64) want=3e00 ;; \
      arm64) want=b700 ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    got="$(od -An -tx1 -j18 -N2 /psclient | tr -d ' \n')"; \
    [ "$got" = "$want" ] \
      || { echo "upstream binary has e_machine ${got}, expected ${want} for ${TARGETARCH}" >&2; exit 1; }

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=check /psclient /usr/local/bin/psclient

# The client keeps a lock and its state under the user config dir
# ($HOME/.config). The compose files and init script mount a 1 MB tmpfs on
# the home dir, so it works on a read-only rootfs and nothing is kept.
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# Tells the client it runs in Docker, which turns off its self-updater (it
# would otherwise download and replace its own binary).
ENV PS_IS_DOCKER=true

# The binary is Go 1.26, which already sizes GOMAXPROCS from the container's
# CPU quota. GOMEMLIMIT makes the GC work harder as the heap nears 48 MiB,
# below the 64 MB container cap, instead of growing until the OOM killer
# steps in.
ENV GOMEMLIMIT=48MiB

# The only required setting is CID (the PacketStream customer ID), from the
# environment.
ENTRYPOINT ["/usr/local/bin/psclient"]

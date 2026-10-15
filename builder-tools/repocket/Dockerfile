# Repocket on a current distroless base, as nonroot. The official image is
# already distroless (cc-debian12), but forces USER 0:0 and carries libraries
# the client never loads (OpenSSL, libstdc++, libgomp). The client is a Rust
# binary using rustls, dynamically linked against glibc and libgcc_s only, so
# distroless/cc (glibc + libgcc, CA certs, tzdata, a nonroot user, no shell)
# is the smallest base it runs on. Upstream publishes a proper multi-arch
# index, so buildx picks the matching binary for each target platform.
FROM repocket/repocket:latest AS upstream

# Runs on the build host (no QEMU): ELF e_machine at offset 18 is 0x3e for
# x86_64 and 0xb7 for aarch64. The binary is never executed at build time;
# it connects out as soon as it starts.
FROM --platform=$BUILDPLATFORM busybox:1.37-musl AS check
ARG TARGETARCH
COPY --from=upstream /usr/local/bin/repocket /repocket
RUN case "$TARGETARCH" in \
      amd64) want=3e00 ;; \
      arm64) want=b700 ;; \
      *) echo "unsupported TARGETARCH ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    got="$(od -An -tx1 -j18 -N2 /repocket | tr -d ' \n')"; \
    [ "$got" = "$want" ] \
      || { echo "upstream binary has e_machine ${got}, expected ${want} for ${TARGETARCH}" >&2; exit 1; }

FROM gcr.io/distroless/cc-debian13:nonroot
COPY --from=check /repocket /usr/local/bin/repocket

# The client writes nothing to disk (the device is registered by the server
# on every connection), so there is no data dir to mount.
WORKDIR /home/nonroot

# The client runs on tokio, which reads this: one async worker thread. Rust
# already sizes the default from the container's CPU quota, so this only
# matters if the container runs without a CPU cap.
ENV TOKIO_WORKER_THREADS=1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/repocket"]

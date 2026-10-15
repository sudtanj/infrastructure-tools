# Honeygain on distroless: the official image's binary and its two shared
# libraries, moved onto gcr.io/distroless/cc (glibc + libgcc/libstdc++ + CA
# certs, no shell, no package manager). Upstream ships amd64 and arm64, so
# buildx picks the matching upstream layer for each target platform.
#
# The upstream base is Debian trixie, so the distroless base is debian13 to
# keep the same glibc.
ARG HONEYGAIN_VERSION=0.9.0

FROM honeygain/honeygain:${HONEYGAIN_VERSION} AS upstream

FROM gcr.io/distroless/cc-debian13:nonroot
COPY --from=upstream /app/honeygain /usr/local/bin/honeygain
COPY --from=upstream /usr/lib/libhg.so* /usr/lib/
COPY --from=upstream /usr/lib/libmsquic.so.2* /usr/lib/
ENV LD_LIBRARY_PATH=/usr/lib

# The binary lives outside the home directory so a volume there (device
# state) never hides a newer binary after an image update. distroless's
# nonroot home is already owned by uid 65532; HOME and the working directory
# both point at it, whichever one Honeygain writes to.
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# Build-time smoke test, run under QEMU for arm64. Distroless has no ldd, so
# running the binary is how a shared library missing from the base shows up:
# the loader fails and the build stops instead of the container on the Pi.
RUN ["/usr/local/bin/honeygain", "-tou-get"]

ENTRYPOINT ["/usr/local/bin/honeygain"]

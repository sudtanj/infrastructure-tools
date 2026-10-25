# syntax=docker/dockerfile:1
# EarnApp (Bright Data) on distroless. Upstream ships no image: its installer
# downloads one binary per arch (a Node.js app packed with pkg, dynamically
# linked against glibc and libstdc++) and runs it as root under systemd with an
# auto-upgrader. Here the same binary is pinned by checksum, put on
# gcr.io/distroless/cc (glibc, libstdc++, a nonroot user, no shell) and run as
# uid 65532, with no upgrader: a new version is a new image.
#
# The binaries are fetched on the build host (no QEMU); ADD picks only the
# target arch's stage. Version and hashes come from the installer at
# https://brightdata.com/static/earnapp/install.sh (VERSION=, then
# cdn-earnapp.b-cdn.net/static/earnapp-<x64|aarch64>-<version>).
ARG EARNAPP_VERSION=1.665.73

FROM scratch AS client-amd64
ARG EARNAPP_VERSION
ARG EARNAPP_SHA256_AMD64=a5080f9eff9df9f59a2192ccafc344f06259bfffe2a0aee619d44c8cafbd8def
ADD --checksum=sha256:${EARNAPP_SHA256_AMD64} https://cdn-earnapp.b-cdn.net/static/earnapp-x64-${EARNAPP_VERSION} /earnapp

FROM scratch AS client-arm64
ARG EARNAPP_VERSION
ARG EARNAPP_SHA256_ARM64=e3ba9761b1416eaa4b97523ce885068d5df8841f3433b2c90e72e3b6edca2d2d
ADD --checksum=sha256:${EARNAPP_SHA256_ARM64} https://cdn-earnapp.b-cdn.net/static/earnapp-aarch64-${EARNAPP_VERSION} /earnapp

FROM client-${TARGETARCH} AS client

# The entrypoint (entry/main.go): the image has no shell, and the client needs
# its device ID and status written to /etc/earnapp before it starts.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS entry
ARG TARGETARCH
COPY entry/ /src/
RUN cd /src && CGO_ENABLED=0 GOOS=linux GOARCH="$TARGETARCH" \
      go build -trimpath -ldflags '-s -w' -o /earnapp-entry .

FROM gcr.io/distroless/cc-debian13:nonroot
COPY --from=client --chmod=0755 /earnapp /usr/bin/earnapp
COPY --from=entry /earnapp-entry /usr/local/bin/earnapp-entry

# The client keeps everything (device ID, status, its encrypted logs, which
# rotate at 3 MB x 2) in /etc/earnapp. The compose files and init script mount
# a 16 MB tmpfs there, so it works on a read-only rootfs; the entrypoint
# writes the device ID back on every start.
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# Node 16 sizes its heap from the host's RAM, not the container's cap. This
# makes the GC work harder near 96 MiB, below the 160 MB container cap,
# instead of growing until the OOM killer steps in.
ENV NODE_OPTIONS=--max-old-space-size=96

ENTRYPOINT ["/usr/local/bin/earnapp-entry"]

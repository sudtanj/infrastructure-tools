# syntax=docker/dockerfile:1
# EarnApp (Bright Data) on distroless, rebuilt on the current Node.js LTS.
# Upstream ships no image: its installer downloads one binary per arch, a
# Node.js 16 app (end of life) packed with pkg, and runs it as root under
# systemd with an auto-upgrader.
#
# Here the upstream binary is pinned by checksum and only used as an archive:
# its JavaScript (identical in the x64 and aarch64 builds, plain source, no
# native add-ons) is unpacked without running it, bundled into one file with
# esbuild, and built into a Node.js 24 single executable (SEA) with V8's
# compile cache made at build time on the target arch. The result runs as
# uid 65532 on gcr.io/distroless/cc, with no upgrader: a new version is a new
# image. Version and hash come from the installer at
# https://brightdata.com/static/earnapp/install.sh (VERSION=, then
# cdn-earnapp.b-cdn.net/static/earnapp-x64-<version>).
ARG EARNAPP_VERSION=1.665.73

FROM scratch AS upstream
ARG EARNAPP_VERSION
ARG EARNAPP_SHA256=a5080f9eff9df9f59a2192ccafc344f06259bfffe2a0aee619d44c8cafbd8def
ADD --checksum=sha256:${EARNAPP_SHA256} https://cdn-earnapp.b-cdn.net/static/earnapp-x64-${EARNAPP_VERSION} /earnapp-pkg

# Unpack and bundle on the build host. Modules marked external are optional
# and missing from upstream's package too (loaded lazily or inside try);
# mocha (the CLI's self-test) is swapped for a stub. The CLI copy of rc4.js
# also goes next to peer_node's cipher, which asks for it but upstream left
# it out. Whitespace-only minification: one CLI file decrypts itself with a
# key taken from its own source text, so identifiers stay as they are.
FROM --platform=$BUILDPLATFORM node:24.22.1-trixie-slim AS bundle
RUN npm install --global --no-audit --no-fund esbuild@0.28.2 postject@1.0.0-alpha.6
COPY build/ /build/
COPY --from=upstream /earnapp-pkg /tmp/earnapp-pkg
WORKDIR /build
RUN node pkg-extract.js /tmp/earnapp-pkg /src \
 && rm /tmp/earnapp-pkg \
 && { [ -e /src/svc/peer_node/rc4.js ] || cp /src/svc/earnapp_cli/earnapp/rc4.js /src/svc/peer_node/rc4.js; } \
 && esbuild /src/svc/earnapp_cli/earnapp/index.js --bundle --platform=node \
      --target=node24 --format=cjs --minify-whitespace --legal-comments=none \
      --alias:mocha=./no-mocha.js \
      --external:tweetnacl --external:iniparser --external:snappystream \
      --external:../root_ca.js --external:./zcounter.js \
      --log-level=warning --outfile=/out/earnapp.js \
 && node --check /out/earnapp.js

# The SEA blob with its compile cache has to be made by the same Node.js
# binary and arch it will run on (QEMU for arm64), with the same V8 flags.
FROM node:24.22.1-trixie-slim AS sea
ENV NODE_OPTIONS=--max-old-space-size=96
COPY --from=bundle /out/earnapp.js /sea/earnapp.js
WORKDIR /sea
RUN printf '%s' '{"main":"earnapp.js","output":"earnapp.blob","disableExperimentalSEAWarning":true,"useCodeCache":true}' > sea.json \
 && node --experimental-sea-config sea.json

# Injecting the blob only edits the ELF file, so it runs on the build host.
FROM bundle AS inject
COPY --from=sea /usr/local/bin/node /out/earnapp
COPY --from=sea /sea/earnapp.blob /out/earnapp.blob
RUN postject /out/earnapp NODE_SEA_BLOB /out/earnapp.blob \
      --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2

# Smoke test on the target arch: loads every module (including the
# self-decrypting one) and prints the version, without connecting anywhere.
FROM node:24.22.1-trixie-slim AS check
ARG EARNAPP_VERSION
COPY --from=inject /out/earnapp /usr/bin/earnapp
RUN out="$(timeout 120 /usr/bin/earnapp --version)" \
 && echo "$out" && [ "$out" = "earnapp ${EARNAPP_VERSION}" ]

# The entrypoint (entry/main.go): the image has no shell, and the client needs
# its device ID and status written to /etc/earnapp before it starts.
FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS entry
ARG TARGETARCH
COPY entry/ /src/
RUN cd /src && CGO_ENABLED=0 GOOS=linux GOARCH="$TARGETARCH" \
      go build -trimpath -ldflags '-s -w' -o /earnapp-entry .

FROM gcr.io/distroless/cc-debian13:nonroot
COPY --from=check /usr/bin/earnapp /usr/bin/earnapp
COPY --from=entry /earnapp-entry /usr/local/bin/earnapp-entry

# The client keeps everything (device ID, status, its encrypted logs, which
# rotate at 3 MB x 2) in /etc/earnapp. The compose files and init script mount
# a 16 MB tmpfs there, so it works on a read-only rootfs; the entrypoint
# writes the device ID back on every start.
ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# Caps the JS heap at 96 MiB, below the 160 MB container cap, so the GC works
# harder instead of the OOM killer stepping in. Must match the sea stage, or
# V8 drops the compile cache.
ENV NODE_OPTIONS=--max-old-space-size=96

ENTRYPOINT ["/usr/local/bin/earnapp-entry"]

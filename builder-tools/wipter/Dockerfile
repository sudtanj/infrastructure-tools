# syntax=docker/dockerfile:1
# Wipter, headless. Upstream ships only a desktop app (Electron 41): its
# window is the client (sign-in, the connection to Wipter), its main process
# serves the proxied traffic, and wipter-tunnel (a small static binary)
# carries it. Community images run it under Xvfb + a window manager + VNC,
# with a keyring, and type the login into the window.
#
# Here the official .deb is pinned by checksum (the versioned URL from the
# app's own update feed, https://provider-assets.wipter.com/latest/linux/
# <x64|arm64>/latest-linux*.yml) and run on a bare Xvfb: no window manager,
# VNC or keyring. app.asar becomes
# wipter.asar and shim/shim.js goes in resources/app/, which Electron then
# loads (this build allows it: its OnlyLoadAppFromAsar fuse is off). The shim
# loads the app's own main process unchanged and, from inside it, signs in, accepts the consent prompt
# and keeps sharing on: no DevTools port or pipe (Electron ignores
# --remote-debugging-pipe, and a port would be reachable through the
# traffic the app relays). entry/main.go starts it and keeps only the shim's
# status lines. Runs as uid 65532 on debian:trixie-slim with only the
# libraries the Electron binary links against.
ARG WIPTER_VERSION=1.25.1012
ARG WIPTER_BUILD=20261005140844_1_25_1012

FROM scratch AS deb-amd64
ARG WIPTER_BUILD
ADD --checksum=sha256:d29751d147f042abab3f64e1a3b803f485338e9f328b34542055d5ed0b0c7a42 \
    https://provider-assets.wipter.com/desktop_app/${WIPTER_BUILD}/linux/x64/wipter-app-amd64.deb /wipter.deb

FROM scratch AS deb-arm64
ARG WIPTER_BUILD
ADD --checksum=sha256:4e0d5bd63964eb2435bca35424f3f29d668ba81a2d2b6196956f782879233c9f \
    https://provider-assets.wipter.com/desktop_app/${WIPTER_BUILD}/linux/arm64/wipter-app-arm64.deb /wipter.deb

FROM deb-${TARGETARCH} AS deb

# Unpacked on the build host, without running the package scripts (they only
# add a symlink, the setuid sandbox and an AppArmor profile). Dropped: the
# setuid sandbox (unused with --no-sandbox), the Vulkan loader and SwiftShader
# (the software GPU, unused with --disable-gpu --disable-software-rasterizer),
# the 2x-scale resources, every locale but en-US, and the 19 MB Chromium
# licence page. The package ships its files world-writable:
# no longer. The shim's package.json keeps the app's name
# and version: they set its profile folder (~/.config/wipter-app) and the
# version it reports.
FROM --platform=$BUILDPLATFORM debian:trixie-slim AS unpack
ARG WIPTER_VERSION
COPY --from=deb /wipter.deb /tmp/wipter.deb
COPY shim/shim.js /x/opt/Wipter/resources/app/shim.js
RUN dpkg-deb -f /tmp/wipter.deb Version | grep -qx "${WIPTER_VERSION}" \
 && dpkg-deb -x /tmp/wipter.deb /x \
 && cd /x/opt/Wipter \
 && rm -f chrome-sandbox LICENSES.chromium.html wipter-app \
      libvk_swiftshader.so vk_swiftshader_icd.json libvulkan.so.1 chrome_200_percent.pak \
 && mv resources/app.asar resources/wipter.asar \
 && chmod -R go-w /x/opt/Wipter \
 && find locales -type f ! -name en-US.pak -delete \
 && test -x wipter-app.bin \
 && test -x resources/wipter-tunnel/wipter-tunnel_0.1.0_linux/wipter-tunnel \
 && printf '{"name":"wipter-app","version":"%s","main":"shim.js","private":true}\n' "${WIPTER_VERSION}" > resources/app/package.json

FROM --platform=$BUILDPLATFORM golang:1.26-alpine AS entry
ARG TARGETARCH
COPY entry/ /src/
RUN cd /src && CGO_ENABLED=0 GOOS=linux GOARCH="$TARGETARCH" \
      go build -trimpath -ldflags '-s -w' -o /wipter-entry .

# What wipter-app.bin links against, plus Xvfb, nothing else: no window
# manager, VNC, fonts beyond what cairo pulls in, or shell tools. libgbm1
# drags in Mesa's drivers and LLVM (~150 MB) only for the GPU, which isn't
# used (--disable-gpu, Xvfb without GLX): removed, as are translations and
# icon themes nothing displays.
# The app reads its user name (os.userInfo), so uid 65532 gets a passwd entry.
FROM debian:trixie-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
      libcairo2 libcups2t64 libdbus-1-3 libexpat1 libgbm1 libglib2.0-0t64 \
      libgtk-3-0t64 libnspr4 libnss3 libpango-1.0-0 libudev1 libx11-6 \
      libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 \
      libxrandr2 xvfb \
 && for p in mesa-libgallium libgl1-mesa-dri libglx-mesa0 mesa-vulkan-drivers libvulkan1 \
            libllvm19 libz3-4 libdrm-amdgpu1 libdrm-radeon1 libdrm-nouveau2 libdrm-intel1; do \
      if dpkg-query -W -f '${Status}' "$p" 2>/dev/null | grep -qx 'install ok installed'; then \
        dpkg --purge --force-depends "$p"; fi; done \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/log/* /usr/share/doc /usr/share/man /usr/share/info \
      /usr/share/locale /usr/share/icons/Adwaita \
 && echo 'nonroot:x:65532:65532:nonroot:/home/nonroot:/usr/sbin/nologin' >> /etc/passwd \
 && echo 'nonroot:x:65532:' >> /etc/group \
 && mkdir -p /home/nonroot/.config \
 && chown -R 65532:65532 /home/nonroot
COPY --from=unpack /x/opt/Wipter /opt/Wipter
COPY --from=entry /wipter-entry /usr/local/bin/wipter-entry

# Every library resolves, on both arches; on amd64 (native, so fast) the app
# also starts on Xvfb and shows its sign-in form, with a throwaway profile,
# and reports its memory. The largest packages and folders are listed too.
FROM runtime AS check
ARG TARGETARCH
RUN ! ldd /opt/Wipter/wipter-app.bin /usr/bin/Xvfb | grep -F 'not found' \
 && dpkg-query -W -f '${Installed-Size}\t${Package}\n' | sort -rn | head -20 \
 && du -xsk /opt/Wipter /usr/lib/* /usr/share/* 2>/dev/null | sort -rn | head -15
USER 65532:65532
RUN if [ "$TARGETARCH" = amd64 ]; then WIPTER_DEBUG=1 timeout 300 /usr/local/bin/wipter-entry -selftest; fi \
 && touch /tmp/check-ok

FROM runtime
COPY --from=check /tmp/check-ok /tmp/check-ok
RUN rm /tmp/check-ok
USER 65532:65532
ENV HOME=/home/nonroot
WORKDIR /home/nonroot
# The app's profile (session, device ID, settings): keep it on a volume so a
# restart doesn't sign in again or count as a new device.
VOLUME ["/home/nonroot/.config"]
ENTRYPOINT ["/usr/local/bin/wipter-entry"]

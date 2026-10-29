# syntax=docker/dockerfile:1
# Everything the Grass job needs on the Instabox runner, built ahead of time: the
# job only downloads this image's files from Docker Hub (it has no Docker) and
# runs run.sh. Not meant to be run as a container: FROM scratch.
#
#   rt/chrome/    stock google-chrome-stable from Google's .deb, with every
#                 library it needs, relocated to run from /tmp/grass-rt (run.sh
#                 links it there) without the host's libraries
#   rt/bin/       Xvfb (+ xkbcomp) for Chrome's screen, x11vnc for the VNC view
#   graftcp       sends Chrome's connections to tailscaled's SOCKS5 port by
#                 tracing its syscalls (same build as wipter-bundle; keep in sync)
#   tailscale(d)  userspace Tailscale, from the official image
#   run.sh        wires them together, see its header
#
# Chrome is unmodified apart from the relocation; the Grass extension is not in
# the image: it is installed from the Chrome Web Store into the saved profile.

# Google's current stable Chrome with its Debian dependencies and some fonts.
# The weekly no-cache rebuild picks up a newer Chrome.
FROM debian:trixie-slim AS chrome
ADD https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb /tmp/chrome.deb
RUN apt-get update \
 && apt-get install -y --no-install-recommends /tmp/chrome.deb \
      fonts-liberation fonts-dejavu-core fonts-noto-color-emoji \
 && rm -rf /var/lib/apt/lists/* /tmp/chrome.deb \
 && /opt/google/chrome/chrome --version

# Relocation, as in wipter-bundle (and as NixOS packages google-chrome): every
# executable gets the bundle's own dynamic loader at a fixed path, and every ELF
# file a forced DT_RPATH (searched for its whole dependency tree and dlopen
# calls, GTK included, unlike RUNPATH) pointing into the bundle. Nothing uses
# LD_LIBRARY_PATH, so programs Chrome starts (xdg-settings, sh, ...) keep the
# host's own libraries. glibc's loader and libc are not patched. Chrome's own
# libraries (ANGLE, SwiftShader) stay next to it ($ORIGIN). Dropped: the
# setuid sandbox helper (a download can't be setuid; see run.sh on the
# sandbox) and the Qt shims (Chrome loads them only on a Qt desktop).
# NSS's modules (softokn, freebl) sit in lib/nss, as on Debian.
# Xvfb runs xkbcomp from a compiled-in dir: "/usr/bin" in Xvfb becomes
# "/tmp/gxb" (same length; wipter-bundle uses /tmp/wxb), which run.sh links to
# rt/bin. GTK's settings schemas go in rt/share; GIO loads no modules and GTK
# no pixbuf loaders or input methods (empty dir and files), so none of the
# host's are mixed in.
FROM debian:trixie-slim AS relocate
RUN apt-get update \
 && apt-get install -y --no-install-recommends patchelf libglib2.0-bin gsettings-desktop-schemas \
      xvfb x11-xkb-utils xkb-data x11vnc \
 && rm -rf /var/lib/apt/lists/*
COPY --from=chrome /opt/google/chrome /out/chrome
COPY --from=chrome /usr/lib/x86_64-linux-gnu /src/lib
COPY --from=chrome /usr/share/fonts /out/fonts
COPY --from=chrome /usr/share/glib-2.0/schemas /src/schemas
RUN set -eu; R=/tmp/grass-rt; mkdir -p /out/lib \
 && rm -f /out/chrome/chrome-sandbox /out/chrome/libqt5_shim.so /out/chrome/libqt6_shim.so \
 && rm -rf /out/chrome/cron \
 # Top-level libraries (files and their soname links) and NSS's module dir.
 && find /src/lib -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -exec cp -a {} /out/lib/ \; \
 && { [ ! -d /src/lib/nss ] || cp -a /src/lib/nss /out/lib/nss; } \
 && cp -L /src/lib/ld-linux-x86-64.so.2 /out/ld-linux-x86-64.so.2 \
 && mkdir -p /out/share/glib-2.0/schemas /out/gio-modules \
 && cp /usr/share/glib-2.0/schemas/*.xml /out/share/glib-2.0/schemas/ \
 && cp --update=none /src/schemas/*.xml /out/share/glib-2.0/schemas/ \
 && glib-compile-schemas /out/share/glib-2.0/schemas \
 && : > /out/gdk-pixbuf-loaders.cache && : > /out/gtk-immodules.cache \
 && mkdir -p /out/bin /out/share/X11 \
 && cp /usr/bin/Xvfb /usr/bin/xkbcomp /usr/bin/x11vnc /out/bin/ \
 && cp -a /usr/share/X11/xkb /out/share/X11/xkb \
 && for l in $(ldd /usr/bin/Xvfb /usr/bin/xkbcomp /usr/bin/x11vnc | awk '$2 == "=>" { print $3 }' | sort -u); do \
      [ -e "/out/lib/${l##*/}" ] || cp -L "$l" /out/lib/; done \
 && perl -0777 -pi -e '$n = s{/usr/bin\0}{/tmp/gxb\0}g; END { print STDERR "Xvfb: /usr/bin -> /tmp/gxb ($n)\n"; exit($n ? 0 : 1) }' /out/bin/Xvfb \
 && n=0; for f in $(find /out/chrome /out/lib /out/bin -type f); do \
      case "${f##*/}" in ld-linux-x86-64.so.2|libc.so.6) continue ;; esac; \
      patchelf --print-rpath "$f" >/dev/null 2>&1 || continue; \
      if patchelf --print-interpreter "$f" >/dev/null 2>&1; then \
        patchelf --set-interpreter "$R/ld-linux-x86-64.so.2" "$f"; fi; \
      case "$f" in /out/chrome/*) rp="\$ORIGIN:$R/lib" ;; *) rp="$R/lib" ;; esac; \
      patchelf --force-rpath --set-rpath "$rp" "$f"; n=$((n + 1)); \
    done; echo "relocated $n ELF files" \
 && [ "$(patchelf --print-interpreter /out/chrome/chrome)" = "$R/ld-linux-x86-64.so.2" ] \
 # Fontconfig: the host may have no /etc/fonts; the bundle's fonts only, cache in $HOME.
 && printf '%s\n' '<?xml version="1.0"?>' '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">' \
      '<fontconfig>' "  <dir>$R/fonts</dir>" '  <cachedir prefix="xdg">fontconfig</cachedir>' '</fontconfig>' \
      > /out/fonts.conf

FROM --platform=$BUILDPLATFORM golang:1.26-trixie AS build
# graftcp: the same pin and patch as wipter-bundle and proxyrack-bundle (see
# proxyrack-bundle/Dockerfile); bump them together.
ARG GRAFTCP_REF=v0.8.3
ARG GRAFTCP_COMMIT=825cf6d3b9ec043defe8e598eb218eccc1a3eaf3
RUN git clone -q --depth 1 --branch "$GRAFTCP_REF" https://github.com/hmgle/graftcp.git /src/graftcp \
 && [ "$(git -C /src/graftcp rev-parse HEAD)" = "$GRAFTCP_COMMIT" ]
RUN cd /src/graftcp/local/cmd/mgraftcp \
 && sed -i 's#^\t"path/filepath"$#&\n\t"runtime"#; s#^func init() {$#&\n\truntime.LockOSThread()#' main.go \
 && grep -q 'runtime.LockOSThread()' main.go && grep -q '"runtime"' main.go
RUN make -C /src/graftcp local/graftcp \
      GO_LDFLAGS='-s -w -linkmode external -extldflags -static' \
 && ! ldd /src/graftcp/local/graftcp 2>/dev/null | grep -q '=>'

# Stands in for the runner: Alpine has no glibc, so a library that resolved
# outside the bundle would fail here. Same layout as run.sh (files in a work
# dir, linked from /tmp/grass-rt), as a non-root user: every library resolves
# inside the bundle, Chrome renders a page headless, then runs windowed on the
# bundle's Xvfb under graftcp (no proxy listening, so every connection fails,
# which the check doesn't need) and is still up after 30 s.
FROM alpine:3.22 AS check
RUN adduser -D -u 1001 runner
COPY --from=relocate --chown=1001:1001 /out /home/runner/w/rt
COPY --from=build /src/graftcp/local/graftcp /usr/local/bin/
USER 1001
ENV FONTCONFIG_FILE=/tmp/grass-rt/fonts.conf XDG_DATA_DIRS=/tmp/grass-rt/share \
    GIO_MODULE_DIR=/tmp/grass-rt/gio-modules GDK_PIXBUF_MODULE_FILE=/tmp/grass-rt/gdk-pixbuf-loaders.cache \
    GTK_IM_MODULE_FILE=/tmp/grass-rt/gtk-immodules.cache
RUN set -eu; ln -s /home/runner/w/rt /tmp/grass-rt && ln -s /tmp/grass-rt/bin /tmp/gxb \
 && for e in chrome/chrome chrome/chrome_crashpad_handler bin/Xvfb bin/xkbcomp bin/x11vnc; do \
      /tmp/grass-rt/ld-linux-x86-64.so.2 --list /tmp/grass-rt/$e; done > /tmp/libs \
 && ! grep -F 'not found' /tmp/libs \
 && ! grep '=>' /tmp/libs | grep -v '=> /tmp/grass-rt/' \
 && echo "$(grep -c '=>' /tmp/libs) libraries, all in the bundle" \
 && /tmp/grass-rt/chrome/chrome --version \
 && mkdir /tmp/h \
 && if ! HOME=/tmp/h timeout 120 /tmp/grass-rt/chrome/chrome --headless=new --no-sandbox \
         --disable-gpu --disable-dev-shm-usage --no-first-run --user-data-dir=/tmp/h/p \
         --dump-dom 'data:text/html,<p>grass-bundle-selftest</p>' > /tmp/dom 2>/tmp/err \
       || ! grep -q 'grass-bundle-selftest' /tmp/dom; then tail -n 30 /tmp/err; exit 1; fi \
 && echo "headless Chrome rendered a page"
# (Links from the step before.)
RUN set -eu; rm -rf /tmp/h; mkdir -p /tmp/h /tmp/.X11-unix; rm -f /tmp/.X96-lock /tmp/.X11-unix/X96; \
    /tmp/grass-rt/bin/Xvfb :96 -screen 0 1280x800x24 -nolisten tcp -extension GLX \
      -xkbdir /tmp/grass-rt/share/X11/xkb >/dev/null 2>&1 & x=$!; \
    for i in $(seq 50); do [ -S /tmp/.X11-unix/X96 ] && break; sleep 0.2; done; \
    HOME=/tmp/h DISPLAY=:96 graftcp --not-ignore-local --select_proxy_mode only_socks5 --socks5 127.0.0.1:1 -- \
      /tmp/grass-rt/chrome/chrome --no-sandbox --ozone-platform=x11 --disable-gpu \
        --disable-dev-shm-usage --no-first-run --user-data-dir=/tmp/h/p about:blank > /tmp/err 2>&1 & c=$!; \
    sleep 30; \
    if ! kill -0 $c 2>/dev/null; then echo "Chrome exited early"; tail -n 30 /tmp/err; exit 1; fi; \
    kill $c $x 2>/dev/null || true; \
    echo "windowed Chrome ran 30 s under graftcp"
# x11vnc serves the bundle's Xvfb and asks for the password (the RFB greeting).
RUN set -eu; rm -f /tmp/.X98-lock /tmp/.X11-unix/X98; printf 'test\n' > /tmp/vp \
 && { /tmp/grass-rt/bin/Xvfb :98 -screen 0 1024x800x16 -nolisten tcp -extension GLX \
        -xkbdir /tmp/grass-rt/share/X11/xkb >/dev/null 2>&1 & } && x=$! \
 && for i in $(seq 50); do [ -S /tmp/.X11-unix/X98 ] && break; sleep 0.2; done \
 && { /tmp/grass-rt/bin/x11vnc -display :98 -localhost -rfbport 5999 -passwdfile /tmp/vp \
        -nolookup -once >/tmp/vnc.log 2>&1 & } && v=$! \
 && sleep 3 && banner="$( (sleep 2) | timeout 5 nc 127.0.0.1 5999 | head -c 12 || true)" \
 && echo "x11vnc greeting: $banner" && { kill $v $x 2>/dev/null || true; } \
 && case "$banner" in "RFB 003.00"*) ;; *) tail -n 30 /tmp/vnc.log; exit 1 ;; esac

FROM tailscale/tailscale:v1.104.1 AS tailscale

FROM scratch
COPY --from=check /home/runner/w/rt /rt
COPY --from=build /src/graftcp/local/graftcp /graftcp
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscaled /
COPY --chmod=0755 run.sh /run.sh

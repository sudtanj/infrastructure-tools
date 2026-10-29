# syntax=docker/dockerfile:1
# Everything the Wipter job needs on an ephemeral GitHub runner, built ahead of
# time: the job only downloads this image's files from Docker Hub (it has no
# Docker) and runs run.sh. Not meant to be run as a container: FROM scratch.
#
#   rt/           the Wipter app, its launcher and every library it needs, from
#                 sudtanj/wipter (builder-tools/wipter), relocated to run from
#                 /tmp/wipter-rt (run.sh links it there) without the host's libraries
#   graftcp       sends the app's connections to a SOCKS5 proxy by tracing its
#                 syscalls (same build as proxyrack-bundle; keep in sync)
#   wipter-guard  SOCKS5 filter in front of tailscaled (guard/main.go)
#   tailscale(d)  userspace Tailscale, from the official image
#   rt/bin/x11vnc optional VNC view of the app's screen (run.sh: VNC_VIEWER)
#   run.sh        wires them together, see its header

# The app, shim and launcher as published from builder-tools/wipter: bump with it.
FROM sudtanj/wipter:v0.1.15 AS app

# Relocation, as NixOS does for Electron: every executable gets the bundle's own
# dynamic loader at a fixed path, and every ELF file a forced DT_RPATH (searched
# for its whole dependency tree and dlopen calls, unlike RUNPATH) pointing into
# the bundle. Nothing uses LD_LIBRARY_PATH, so programs the app starts (sh,
# cat, ...) keep the host's own libraries. glibc's loader and libc are not
# patched. The GPU libraries Chromium dlopens stay next to the app ($ORIGIN).
# GTK's settings schemas go in rt/share, the bundle's only XDG data dir; GIO
# loads no modules (an empty dir), so none of the host's are mixed in.
# Xvfb (Chromium's headless backend hangs Electron) comes from the same Debian
# release, with xkbcomp, which it runs from a compiled-in dir: the string
# "/usr/bin" in Xvfb becomes "/tmp/wxb" (same length), which run.sh links to
# rt/bin. Its keyboard data goes in rt/share/X11/xkb (passed with -xkbdir).
# x11vnc, for the optional VNC view, is relocated the same way.
FROM debian:trixie-slim AS relocate
RUN apt-get update \
 && apt-get install -y --no-install-recommends patchelf libglib2.0-bin gsettings-desktop-schemas \
      xvfb x11-xkb-utils xkb-data x11vnc \
 && rm -rf /var/lib/apt/lists/*
COPY --from=app /opt/Wipter /out/app
COPY --from=app /usr/lib/x86_64-linux-gnu /src/lib
COPY --from=app /usr/share/fonts /out/fonts
COPY --from=app /usr/local/bin/wipter-entry /out/wipter-entry
RUN set -eu; R=/tmp/wipter-rt; mkdir -p /out/lib \
 # Top-level libraries only (files and their soname links); the module dirs
 # (gio, gdk-pixbuf, perl, ...) aren't used.
 && find /src/lib -maxdepth 1 \( -type f -o -type l \) -name '*.so*' -exec cp -a {} /out/lib/ \; \
 && cp -L /src/lib/ld-linux-x86-64.so.2 /out/ld-linux-x86-64.so.2 \
 && mkdir -p /out/share/glib-2.0/schemas /out/gio-modules \
 && cp /usr/share/glib-2.0/schemas/*.xml /out/share/glib-2.0/schemas/ \
 && glib-compile-schemas /out/share/glib-2.0/schemas \
 && mkdir -p /out/bin /out/share/X11 \
 && cp /usr/bin/Xvfb /usr/bin/xkbcomp /usr/bin/x11vnc /out/bin/ \
 && cp -a /usr/share/X11/xkb /out/share/X11/xkb \
 && for l in $(ldd /usr/bin/Xvfb /usr/bin/xkbcomp /usr/bin/x11vnc | awk '$2 == "=>" { print $3 }' | sort -u); do \
      [ -e "/out/lib/${l##*/}" ] || cp -L "$l" /out/lib/; done \
 && perl -0777 -pi -e '$n = s{/usr/bin\0}{/tmp/wxb\0}g; END { print STDERR "Xvfb: /usr/bin -> /tmp/wxb ($n)\n"; exit($n ? 0 : 1) }' /out/bin/Xvfb \
 && n=0; for f in $(find /out/app /out/lib /out/bin -type f); do \
      case "${f##*/}" in ld-linux-x86-64.so.2|libc.so.6) continue ;; esac; \
      patchelf --print-rpath "$f" >/dev/null 2>&1 || continue; \
      if patchelf --print-interpreter "$f" >/dev/null 2>&1; then \
        patchelf --set-interpreter "$R/ld-linux-x86-64.so.2" "$f"; fi; \
      case "$f" in /out/app/*) rp="\$ORIGIN:$R/lib" ;; *) rp="$R/lib" ;; esac; \
      patchelf --force-rpath --set-rpath "$rp" "$f"; n=$((n + 1)); \
    done; echo "relocated $n ELF files" \
 && [ "$(patchelf --print-interpreter /out/app/wipter-app.bin)" = "$R/ld-linux-x86-64.so.2" ] \
 # Fontconfig: the host may have no /etc/fonts; the bundle's fonts only, cache in $HOME.
 && printf '%s\n' '<?xml version="1.0"?>' '<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">' \
      '<fontconfig>' "  <dir>$R/fonts</dir>" '  <cachedir prefix="xdg">fontconfig</cachedir>' '</fontconfig>' \
      > /out/fonts.conf

FROM --platform=$BUILDPLATFORM golang:1.26-trixie AS build
# graftcp: the same pin and patch as proxyrack-bundle/Dockerfile (see there); bump both together.
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
COPY guard/ /src/guard/
RUN cd /src/guard && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o /wipter-guard .

# Stands in for the runner: Alpine has no glibc, so a library that resolved
# outside the bundle would fail here. Same layout as run.sh (files in a work
# dir, linked from /tmp/wipter-rt), as a non-root user: every library
# resolves inside the bundle, then the app starts on the bundle's Xvfb and
# shows its sign-in form, and reports its memory. Then the same under graftcp
# and the guard, as run.sh starts it (no upstream here, so every connection
# fails, which the self-test doesn't need): Chromium and all its helpers run
# traced.
FROM alpine:3.22 AS check
RUN adduser -D -u 1001 runner
COPY --from=relocate --chown=1001:1001 /out /home/runner/w/rt
COPY --from=build /src/graftcp/local/graftcp /wipter-guard /usr/local/bin/
USER 1001
RUN set -eu; ln -s /home/runner/w/rt /tmp/wipter-rt && ln -s /tmp/wipter-rt/bin /tmp/wxb \
 && for e in app/wipter-app.bin bin/Xvfb bin/xkbcomp bin/x11vnc; do \
      /tmp/wipter-rt/ld-linux-x86-64.so.2 --list /tmp/wipter-rt/$e; done > /tmp/libs \
 && ! grep -F 'not found' /tmp/libs \
 && ! grep '=>' /tmp/libs | grep -v '=> /tmp/wipter-rt/' \
 && echo "$(grep -c '=>' /tmp/libs) libraries, all in the bundle" \
 && mkdir /tmp/h \
 && HOME=/tmp/h FONTCONFIG_FILE=/tmp/wipter-rt/fonts.conf WIPTER_APP=/tmp/wipter-rt/app/wipter-app.bin \
      XDG_DATA_DIRS=/tmp/wipter-rt/share GIO_MODULE_DIR=/tmp/wipter-rt/gio-modules \
      WIPTER_XVFB=/tmp/wipter-rt/bin/Xvfb WIPTER_XKB_DIR=/tmp/wipter-rt/share/X11/xkb WIPTER_DEBUG=1 timeout 300 /tmp/wipter-rt/wipter-entry -selftest
# (Links from the step before; the killed Xvfb's socket and lock are removed.)
RUN set -eu; rm -rf /tmp/h /tmp/.X99-lock /tmp/.X11-unix/X99 && mkdir /tmp/h \
 && { wipter-guard -listen 127.0.0.1:1083 -upstream 127.0.0.1:1 -local 127.0.0.1:2000 >/dev/null 2>&1 & } \
 && g=$! && sleep 1 \
 && HOME=/tmp/h FONTCONFIG_FILE=/tmp/wipter-rt/fonts.conf WIPTER_APP=/tmp/wipter-rt/app/wipter-app.bin \
      XDG_DATA_DIRS=/tmp/wipter-rt/share GIO_MODULE_DIR=/tmp/wipter-rt/gio-modules \
      WIPTER_XVFB=/tmp/wipter-rt/bin/Xvfb WIPTER_XKB_DIR=/tmp/wipter-rt/share/X11/xkb \
      graftcp --not-ignore-local --select_proxy_mode only_socks5 --socks5 127.0.0.1:1083 \
        --enable-dns --dns-server 94.140.14.15:53 --enable-udp -- \
      timeout 300 /tmp/wipter-rt/wipter-entry -selftest \
 && kill $g
# x11vnc serves the bundle's Xvfb and asks for the password (the RFB greeting).
RUN set -eu; rm -f /tmp/.X98-lock /tmp/.X11-unix/X98; printf 'test\n' > /tmp/vp \
 && { /tmp/wipter-rt/bin/Xvfb :98 -screen 0 1024x800x16 -nolisten tcp -extension GLX \
        -xkbdir /tmp/wipter-rt/share/X11/xkb >/dev/null 2>&1 & } && x=$! \
 && for i in $(seq 50); do [ -S /tmp/.X11-unix/X98 ] && break; sleep 0.2; done \
 && { /tmp/wipter-rt/bin/x11vnc -display :98 -localhost -rfbport 5999 -passwdfile /tmp/vp \
        -nolookup -quiet -once >/dev/null 2>&1 & } && v=$! \
 && sleep 3 && banner="$(timeout 5 nc 127.0.0.1 5999 </dev/null | head -c 12 || true)" \
 && echo "x11vnc greeting: $banner" && { kill $v $x 2>/dev/null || true; } \
 && case "$banner" in "RFB 003.00"*) ;; *) exit 1 ;; esac

FROM tailscale/tailscale:v1.104.1 AS tailscale

FROM scratch
COPY --from=check /home/runner/w/rt /rt
COPY --from=build /src/graftcp/local/graftcp /graftcp
COPY --from=build /wipter-guard /wipter-guard
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscaled /
COPY --chmod=0755 run.sh /run.sh

# syntax=docker/dockerfile:1
# ProxyRack Peer client on distroless. The official image (proxyrack/pop) is
# Ubuntu as root with Node, curl and netcat: its run.sh downloads a JavaScript
# launcher at every start, which then downloads and runs the real client, a
# static Go binary, with no checksum. Here that binary is fetched once at build
# time, pinned by SHA-256, and run directly as uid 65532; it never updates
# itself. Upstream only builds it for x86-64 (amd64 only, see .platforms).
#
# To update: fetch https://app-updates.sock.sh/peerclient/go/version.txt and
# the client next to it, then bump PROXYRACK_SHA256 and the --version below.
FROM --platform=$BUILDPLATFORM busybox:1.37-musl AS check
ARG PROXYRACK_SHA256=ae87ea5376a70acaaadfa934229a260b90b4c2bf39ef0284a0a5a8074442c7b0
# The build fails if upstream replaced the file.
ADD --checksum=sha256:${PROXYRACK_SHA256} https://app-updates.sock.sh/peerclient/go/client /proxyrack
# Never executed at build time. ELF e_machine at offset 18 must be 0x3e
# (x86_64), and the binary must be static (distroless has no loader).
RUN got="$(od -An -tx1 -j18 -N2 /proxyrack | tr -d ' \n')"; \
    [ "$got" = "3e00" ] \
      || { echo "upstream binary has e_machine ${got}, expected 3e00 (x86_64)" >&2; exit 1; }; \
    if grep -q '/lib/ld-' /proxyrack; then \
      echo "upstream binary is dynamically linked; distroless static cannot run it" >&2; exit 1; \
    fi; \
    chmod 0755 /proxyrack

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=check /proxyrack /usr/local/bin/proxyrack

ENV HOME=/home/nonroot
WORKDIR /home/nonroot

# The arguments the official launcher passes. Add the device ID at run time:
#   docker run -i ... sudtanj/proxyrack --id <64-char device id>
# -i matters: the client exits when its stdin closes.
ENTRYPOINT ["/usr/local/bin/proxyrack", \
  "--homeIp", "point-of-presence.sock.sh", "--homePort", "443", \
  "--clientKey", "proxyrack-pop-client", "--clientType", "PoP", \
  "--version", "60", "--osType", "Linux", "--osArch", "x64"]

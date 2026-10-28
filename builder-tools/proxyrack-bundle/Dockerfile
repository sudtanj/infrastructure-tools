# syntax=docker/dockerfile:1
# Everything the ProxyRack job needs on an ephemeral GitHub runner, built ahead
# of time: the job only downloads this image's files from Docker Hub (it has no
# Docker) and runs run.sh. Not meant to be run as a container: FROM scratch.
#
#   proxyrack        the same pinned client as builder-tools/proxyrack
#   graftcp          sends the client's connections to a SOCKS5 proxy by
#                    tracing its syscalls (works on static Go binaries)
#   proxyrack-guard  SOCKS5 filter in front of tailscaled (guard/main.go)
#   tailscale(d)     userspace Tailscale, from the official image
#   run.sh           wires them together, see its header

FROM --platform=$BUILDPLATFORM busybox:1.37-musl AS client
# Same pin as builder-tools/proxyrack/Dockerfile; bump both together.
ARG PROXYRACK_SHA256=ae87ea5376a70acaaadfa934229a260b90b4c2bf39ef0284a0a5a8074442c7b0
ADD --checksum=sha256:${PROXYRACK_SHA256} https://app-updates.sock.sh/peerclient/go/client /proxyrack
RUN chmod 0755 /proxyrack

# Debian (glibc), as upstream builds graftcp; the image already has gcc, make and git.
FROM golang:1.26-trixie AS build
# graftcp v0.8.3, checked against its commit.
ARG GRAFTCP_REF=v0.8.3
ARG GRAFTCP_COMMIT=825cf6d3b9ec043defe8e598eb218eccc1a3eaf3
RUN git clone -q --depth 1 --branch "$GRAFTCP_REF" https://github.com/hmgle/graftcp.git /src/graftcp \
 && [ "$(git -C /src/graftcp rev-parse HEAD)" = "$GRAFTCP_COMMIT" ]
# mgraftcp forks the program in one cgo call and traces it in the next, but Linux only takes
# ptrace calls from the thread that forked it. If Go moves main to another thread in between,
# ptrace fails ("No such process") and the program runs untraced under graftcp's seccomp
# filter, where fcntl returns ENOSYS (Go: "cannot open standard fds"). Pin main to one thread.
RUN cd /src/graftcp/local/cmd/mgraftcp \
 && sed -i 's#^\t"path/filepath"$#&\n\t"runtime"#; s#^func init() {$#&\n\truntime.LockOSThread()#' main.go \
 && grep -q 'runtime.LockOSThread()' main.go && grep -q '"runtime"' main.go
# Static, so it runs on any runner image whatever its glibc. (The linker warns about
# getpwnam in a static binary: only graftcp's -u option uses it, and run.sh doesn't.)
RUN make -C /src/graftcp local/graftcp \
      GO_LDFLAGS='-s -w -linkmode external -extldflags -static' \
 && ! ldd /src/graftcp/local/graftcp 2>/dev/null | grep -q '=>'
COPY guard/ /src/guard/
RUN cd /src/guard && CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o /proxyrack-guard .

FROM tailscale/tailscale:v1.104.1 AS tailscale

FROM scratch
COPY --from=client /proxyrack /proxyrack
COPY --from=build /src/graftcp/local/graftcp /graftcp
COPY --from=build /proxyrack-guard /proxyrack-guard
COPY --from=tailscale /usr/local/bin/tailscale /usr/local/bin/tailscaled /
COPY --chmod=0755 run.sh /run.sh

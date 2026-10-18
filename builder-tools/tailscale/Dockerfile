# Tailscale on distroless: the official image's tailscaled and tailscale
# binaries, moved onto gcr.io/distroless/static (CA certs and tzdata, no libc,
# no shell, no package manager). Upstream publishes every architecture we
# build, so buildx picks the matching upstream layer for each target platform.
#
# The official image is Alpine plus iptables/iproute2 and containerboot. None
# of that is copied: tailscaled reads its settings from a config file
# (--config), so containerboot and a shell are not needed, and it programs the
# firewall through nftables netlink, so no iptables userland.
#
# The tag is written out (no ARG) so Dependabot can bump it.
FROM tailscale/tailscale:v1.104.1 AS upstream

FROM gcr.io/distroless/static-debian13:latest
COPY --from=upstream /usr/local/bin/tailscaled /usr/local/bin/tailscale /usr/local/bin/

# Runs as root: kernel networking (TUN device, routes, nftables) needs
# NET_ADMIN and NET_RAW, and Docker grants added capabilities only to root.
# Compose drops every other capability.
#
# Defaults sized for a small board on an SD card:
# - TS_NO_LOGS_NO_SUPPORT: no log upload to log.tailscale.com and, with it,
#   no on-disk log buffer in the state directory (the main source of steady
#   SD card writes). Tailscale support then can't look at this node's logs.
# - TS_DEBUG_FIREWALL_MODE=nftables: there is no iptables binary in here.
# - HOME and XDG_CACHE_HOME on /tmp, a tmpfs in compose, so cache files never
#   reach the card and the root filesystem can stay read-only.
ENV TS_NO_LOGS_NO_SUPPORT=true \
    TS_DEBUG_FIREWALL_MODE=nftables \
    HOME=/tmp \
    XDG_CACHE_HOME=/tmp/.cache

# Build-time smoke test, run under QEMU for arm64. distroless/static has no
# dynamic loader, so if upstream ever ships a cgo (dynamically linked) build,
# the build stops here instead of the container on the Pi.
RUN ["/usr/local/bin/tailscaled", "--version"]
RUN ["/usr/local/bin/tailscale", "version"]

# Same socket path as the CLI default, so `docker exec <ctr> tailscale status`
# needs no --socket flag.
ENTRYPOINT ["/usr/local/bin/tailscaled", "--statedir=/var/lib/tailscale", "--socket=/var/run/tailscale/tailscaled.sock"]

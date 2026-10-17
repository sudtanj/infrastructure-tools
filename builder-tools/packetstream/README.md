# packetstream

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`packetstream/psclient`](https://hub.docker.com/r/packetstream/psclient)
client (a static Go binary), repackaged on
`gcr.io/distroless/static-debian13:nonroot`. Built for `linux/amd64` and
`linux/arm64` (Orange Pi Zero 3 included).

## What this fixes over the official image

| Official `psclient` | This image |
|---|---|
| On aarch64 the launcher prefers the **32-bit ARMv6** client whenever the kernel can run it (Armbian usually can). That build encrypts the tunnel without the CPU's AES/SHA instructions: slow, and it stalls and reconnects under a CPU cap | The native arm64 (or amd64) binary, picked at build time and run directly |
| A shell launcher that sleeps 10 s and test-runs the 32-bit client on every start | No launcher: the client is the entrypoint, so starts and restarts are immediate |
| Debian bookworm with apt, plus all four arch binaries in every image (~62 MB compressed) | One binary on distroless static (~7 MB compressed) |
| Runs as root | Runs as `nonroot` (uid 65532), works with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| No Go memory limit: the heap grows until the container's OOM kill | `GOMEMLIMIT=48MiB`, so the GC tightens before the 64 MB cap |
| No limits | 0.25 CPU, 64 MB with no swap, 64 pids, small rotated logs |
| Uses the host's resolver, can reach the LAN | AdGuard Family Protection; `init-packetstream.sh` blocks DNS to any other server and all traffic to private, Tailscale, link-local and multicast ranges |

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # CID, PS_DEVICE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

| Variable | Required | Notes |
|---|---|---|
| `CID` | yes | Customer ID from the PacketStream dashboard |
| `PS_DEVICE` | no (default `packetstream`) | Container hostname only |

## Notes

- **Self-update off**: `PS_IS_DOCKER=true` (set in the image) stops the
  client from downloading and replacing its own binary. Updates come from
  the weekly rebuild of this image.
- **No device name**: the client has no device-name option; PacketStream
  lists a device by its IP.
- **Nothing kept**: the client's state lives in `$HOME/.config`, a tmpfs.
- **CPU**: the binary is Go 1.26, which already fits `GOMAXPROCS` to the
  container's CPU cap. This client carries more traffic than the others; if
  it is still choppy at 0.25 CPU, raise the cap for this container only.
- **LAN**: the client already refuses to relay to private addresses; the
  firewall rules in `init-packetstream.sh` are a second layer.
- **Filtered DNS**: the container resolver is AdGuard Family Protection
  (`94.140.14.15`, `94.140.14.16`). The client uses the system resolver.
- **No shell**: `docker exec` won't work. Use `docker logs`.
- **Redistribution**: this image republishes PacketStream's binary. Consider
  making `sudtanj/packetstream` private on Docker Hub.

# bitping

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`bitping/bitpingd`](https://hub.docker.com/r/bitping/bitpingd)
node (a static Rust binary), repackaged on
`gcr.io/distroless/static-debian13:nonroot`. Built for `linux/amd64` and
`linux/arm64` (Orange Pi Zero 3 included).

## What this fixes over the official image

| Official `bitpingd` | This image |
|---|---|
| Alpine with a shell script as PID 1 that relaunches the client (10 s, doubling up to 300 s) | The client is the entrypoint; Docker's restart policy handles restarts |
| Runs as root | Runs as `nonroot` (uid 65532), works with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| Replaces its own binary from `releases.bitping.com` | That host resolves to `127.0.0.1`; new versions come from the weekly rebuild of this image |
| State on a volume (tokens, SQLite) | `~/.bitpingd` on an 8 MB tmpfs: nothing kept, each new container is a new node |
| No limits | 0.25 CPU, 64 MB with no swap, 64 pids, small rotated logs |
| Uses the host's resolver, can reach the LAN | AdGuard Family Protection; `init-bitping.sh` blocks DNS to any other server and all traffic to private, Tailscale, link-local and multicast ranges |

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # BITPING_API_KEY, BITPING_DEVICE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

| Variable | Required | Notes |
|---|---|---|
| `BITPING_API_KEY` | yes | API key from https://app.bitping.com |
| `BITPING_DEVICE` | no (default `bitping`) | Container hostname only |
| `BITPING_MAX_PROXY_SESSIONS` | no | Cap on concurrent proxy sessions |

## Notes

- **What it runs**: monitoring jobs for Bitping's customers (ping, traceroute,
  DNS, HTTP, TCP/UDP, TLS/QUIC, HLS, speed tests) and proxy sessions.
- **No privileges needed**: ping and traceroute fall back to unprivileged
  ICMP sockets, which Docker allows by default.
- **Filtered DNS costs some jobs**: the container only resolves through
  AdGuard Family Protection (`94.140.14.15`, `94.140.14.16`) and other DNS
  servers are blocked, so DNS checks against other resolvers, and checks of
  domains AdGuard blocks, fail. This is deliberate.
- **Email login**: `BITPING_EMAIL` / `BITPING_PASSWORD` (and `BITPING_MFA`)
  also work, but an MFA code expires, so use the API key for unattended runs.
- **Memory**: the home tmpfs counts against the 64 MB limit. If the client
  starts failing to write its database after a long run, raise both.
- **No shell**: `docker exec` won't work. Use `docker logs`.
- **Redistribution**: this image republishes Bitping's binary. Consider
  making `sudtanj/bitping` private on Docker Hub.

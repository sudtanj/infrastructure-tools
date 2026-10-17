# pawns

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`iproyal/pawns-cli`](https://hub.docker.com/r/iproyal/pawns-cli)
client (a static Go binary), repackaged on
`gcr.io/distroless/static-debian13:nonroot`. Built for `linux/amd64` and
`linux/arm64` (Orange Pi Zero 3 included).

## What this fixes over the official image

| Official `pawns-cli` | This image |
|---|---|
| Empty image with a CA bundle, run as root, no `/etc/passwd`, tzdata or `/tmp` | Distroless static, runs as `nonroot` (uid 65532), works with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| Has a UPnP client that can open ports on your router | `init-pawns.sh` drops all traffic from the container to private, Tailscale, link-local and multicast ranges: no UPnP, no reaching your LAN through the relayed traffic |
| Sends crash reports to `sentry.iproyal.com` | That hostname resolves to `127.0.0.1` in the container |
| No Go memory limit: the heap grows until the container's OOM kill | `GOMEMLIMIT=48MiB`, so the GC tightens before the 64 MB cap |
| `--accept-tos` must be added by hand | Always on (entrypoint) |
| `--restart=on-failure:5`, no limits | 0.25 CPU, 64 MB with no swap, 64 pids, small rotated logs |

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # PAWNS_EMAIL, PAWNS_PASSWORD, PAWNS_DEVICE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

| Variable | Required | Notes |
|---|---|---|
| `PAWNS_EMAIL` | yes | Pawns account email |
| `PAWNS_PASSWORD` | yes | Pawns account password |
| `PAWNS_DEVICE` | no (default `pawns`) | Dashboard device name and device ID, also the container hostname |

## Notes

- **Credentials on the command line**: the client only takes flags
  (`-email`, `-password`, `-device-name`, `-device-id`), so the account
  password is visible to root on the device (`ps`, `docker inspect`). Use a
  password you don't use anywhere else.
- **CPU**: the binary is Go 1.25+, which already fits `GOMAXPROCS` to the
  container's CPU cap.
- **Filtered DNS**: the container resolver is AdGuard Family Protection
  (`94.140.14.15`, `94.140.14.16`). The client uses the system resolver.
- **Obfuscated binary**: upstream builds with garble, so its flags and
  behaviour can't be fully checked from the binary.
- **No shell**: `docker exec` won't work. Use `docker logs`.
- **Redistribution**: this image republishes IPRoyal's binary. Consider
  making `sudtanj/pawns` private on Docker Hub.

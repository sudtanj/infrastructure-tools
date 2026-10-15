# repocket

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`repocket/repocket`](https://hub.docker.com/r/repocket/repocket)
client (a Rust binary), repackaged on
`gcr.io/distroless/cc-debian13:nonroot`. Built for `linux/amd64` and
`linux/arm64` (Orange Pi Zero 3 included).

## What this fixes over the official image

The official image is already small and distroless, so the gains are mostly
about privileges:

| Official `repocket` | This image |
|---|---|
| Forces `USER 0:0` (root) | Runs as `nonroot` (uid 65532), works with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| distroless `cc-debian12`, plus OpenSSL, libstdc++ and libgomp the client never loads (it uses rustls) | distroless `cc-debian13`: glibc, libgcc, CA certs, tzdata |
| `--restart=always`, no limits | 0.25 CPU, 64 MB with no swap, 64 pids, small rotated logs |
| Uses the host's resolver | AdGuard Family Protection, and `init-repocket.sh` blocks DNS to any other server |

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # RP_API_KEY, RP_DEVICE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

| Variable | Required | Notes |
|---|---|---|
| `RP_API_KEY` | yes | API key from the Repocket dashboard, must be a UUID |
| `RP_DEVICE` | no (default `repocket`) | Container hostname |

## Notes

- **One setting**: the client only reads `RP_API_KEY`. There is no
  device-name, log-level or tuning option (the old `RP_EMAIL` is gone).
- **Nothing kept**: the client writes nothing to disk; the server registers
  the device on every connection, so each new container is a new device.
- **Server-controlled**: the server sets session caps, UDP relay limits and
  the client's log settings.
- **Filtered DNS**: the client uses the system resolver, so AdGuard Family
  Protection (`94.140.14.15`, `94.140.14.16`) covers its lookups.
- **Logs are identifying**: the client prints its device ID. The init script
  masks IDs and IPs before anything reaches the Actions log.
- **No shell**: `docker exec` won't work. Use `docker logs`.
- **Redistribution**: this image republishes Repocket's binary. Consider
  making `sudtanj/repocket` private on Docker Hub.

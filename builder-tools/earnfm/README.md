# earnfm

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`earnfm/earnfm-client`](https://hub.docker.com/r/earnfm/earnfm-client)
client (a static Go binary), repackaged on
`gcr.io/distroless/static-debian13:nonroot`. Built for `linux/amd64` and
`linux/arm64` (Orange Pi Zero 3 included).

## What this fixes over the official image

| Official `earnfm-client` | This image |
|---|---|
| Alpine base with a shell, apk and busybox (~13 MB compressed) | Distroless static: just the binary, CA certs and tzdata, no shell |
| Runs as root | Runs as `nonroot` (uid 65532), works with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| State in `/var/lib/earnfm`, written into the container layer | `EARNFM_DATA_DIR` on a 1 MB tmpfs: rootfs stays read-only, nothing is kept, each new container is a new device |
| Go 1.23 binary: `GOMAXPROCS` = host cores, ignoring the container CPU cap | `GOMAXPROCS=1`, so a 0.25 CPU cap is not spent on throttled parallel Ps |
| No Go memory limit: the heap grows until the container's OOM kill | `GOMEMLIMIT=48MiB`, so the GC tightens before the 64 MB cap |
| Queries `9.9.9.9` and `1.1.1.1` directly, bypassing the container's resolver | `init-earnfm.sh` redirects those to AdGuard Family Protection (see below) |
| Watchtower every 60 s with the Docker socket mounted | The publish workflow rebuilds weekly without cache. Re-run `init-earnfm` to deploy |

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # EFM_TOKEN, EFM_DEVICE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

| Variable | Required | Notes |
|---|---|---|
| `EFM_TOKEN` | yes | API key from app.earn.fm settings, passed as `EARNFM_TOKEN` |
| `EFM_DEVICE` | no (default `earnfm`) | Dashboard device name (`EARNFM_DEVICE_NAME`), also the container hostname |

## Notes

- **Filtered DNS**: the container resolver is AdGuard Family Protection
  (`94.140.14.15`, `94.140.14.16`), blocking known malware, phishing and adult
  domains. The client also has `9.9.9.9:53` and `1.1.1.1:53` built in, which
  ignore that. `bash-scripts/init-earnfm.sh` rewrites any plain DNS from the
  container to AdGuard (lookups still succeed, filtered) and drops DNS over
  TLS/QUIC. Compose alone cannot, so the compose files only cover the
  system resolver.
- **Client settings**: the binary reads `EARNFM_TOKEN`, `EARNFM_DEVICE_NAME`,
  `EARNFM_DATA_DIR` and `EARNFM_DEBUG` (verbose logs; keep it off on an SD
  card). It has no throughput or tuning options.
- **Logs are identifying**: the client prints its device ID and your public
  IP. The init script masks both before anything reaches the Actions log.
- **No shell**: `docker exec` won't work. Use `docker logs`.
- **Old toolchain**: upstream builds with Go 1.23, which no longer gets
  security fixes. Only EarnFM can rebuild it; the weekly rebuild picks up
  whatever they ship.
- **Redistribution**: this image republishes EarnFM's binary. Consider
  making `sudtanj/earnfm` private on Docker Hub.

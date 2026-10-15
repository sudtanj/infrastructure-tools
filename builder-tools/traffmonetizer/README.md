# traffmonetizer

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`traffmonetizer/cli_v2`](https://hub.docker.com/r/traffmonetizer/cli_v2)
client (a static Rust binary), repackaged on
`gcr.io/distroless/static-debian13:nonroot`. Built for `linux/amd64` and
`linux/arm64` (Orange Pi Zero 3 included).

## What this fixes over the official image

| Official `cli_v2` | This image |
|---|---|
| One tag per arch (`latest`, `arm64v8`), no multi-arch index, and every tag is labelled `linux/amd64` | One multi-arch `latest`; the build checks the ELF header of each binary, so a mislabeled upstream push fails the build |
| Runs as root | Runs as `nonroot` (uid 65532), works with `cap_drop: ALL`, `no-new-privileges` and a read-only rootfs |
| Device ID file written into the container layer, so it needs a writable rootfs | Device ID written to a 1 MB tmpfs and not kept: the rootfs stays read-only, and each new container is a new device |
| One tokio worker thread per host core | `TOKIO_WORKER_THREADS=1`: the work is all network I/O and the CPU cap is below one core |
| No CA bundle, no `/etc/passwd`, no tzdata | Provided by distroless static |
| Watchtower recommended for updates | The publish workflow rebuilds weekly without cache, which picks up new upstream binaries. Re-run `init-traffmonetizer` to deploy them |

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # TM_TOKEN, TM_DEVICE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

| Variable | Required | Notes |
|---|---|---|
| `TM_TOKEN` | yes | Application token from the Traffmonetizer dashboard |
| `TM_DEVICE` | no (default `traffmonetizer`) | Dashboard device name, also the container hostname |

The container runs `cli start accept --token … --device-name …`.

## Notes

- **Filtered DNS**: the container resolves through AdGuard Family Protection
  (`94.140.14.15`, `94.140.14.16`), blocking known malware, phishing and adult
  domains. The binary has no hardcoded resolvers, so this covers its own
  lookups. `bash-scripts/init-traffmonetizer.sh` also firewalls every other
  resolver; compose alone cannot.
- **No shell**: `docker exec` won't work. Use `docker logs`.
- **CLI flags**: the binary has no throughput or tuning flags. Besides
  `--token` and `--device-name` it takes `--device-id <uuid>` (fixed
  device ID instead of the generated one), `--ip`/`--ips` and
  `--device-ids ip=uuid,...` (bind to specific local IPs, for hosts with
  several public IPs) and `--verbose-logging` (off by default; keep it off on
  an SD card).
- **Token visibility**: the binary only takes `--token`, so the token is
  visible in `docker inspect` and `ps` on the host.
- **Pinning upstream**: `TM_TAG_AMD64` / `TM_TAG_ARM64` build args select the
  upstream tags. Upstream publishes no versions, so `latest`/`arm64v8` are
  used.
- **Redistribution**: this image republishes Traffmonetizer's binary.
  Consider making `sudtanj/traffmonetizer` private on Docker Hub.

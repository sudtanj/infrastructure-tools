# honeygain

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works.

The official [`honeygain/honeygain`](https://hub.docker.com/r/honeygain/honeygain)
client, repackaged on `gcr.io/distroless/cc-debian13:nonroot`. Only the
binary, `libhg.so` and `libmsquic.so.2` are copied over; the Debian base,
apt and the shell are dropped. Built for `linux/amd64` and `linux/arm64`
(Orange Pi Zero 3 included).

## Quick start

```bash
cp .env.example .env
$EDITOR .env                       # HG_EMAIL, HG_PASSWORD, HG_DEVICE
docker compose -f docker-compose.hub.yml up -d   # or docker-compose.yml to build
```

| Variable | Required | Notes |
|---|---|---|
| `HG_EMAIL` | yes | Honeygain account email |
| `HG_PASSWORD` | yes | Honeygain account password |
| `HG_DEVICE` | no (default `honeygain`) | Dashboard device name, also the container hostname. Unique per running instance. |

`-tou-accept` is always passed. Keep `HG_DEVICE` the same across recreates,
otherwise every recreate shows up as a new device.

## Notes

- **No shell**: `docker exec` won't work. Use `docker logs`, or run the
  official image to debug.
- **Password visibility**: the binary only takes `-pass`, so the password is
  visible in `docker inspect` and `ps` on the host.
- **Updating Honeygain**: bump `HONEYGAIN_VERSION` in the `Dockerfile`. The
  build runs `honeygain -tou-get` as a smoke test, so a shared library
  missing from distroless fails the build rather than the container.
- **Redistribution**: this image republishes Honeygain's binaries. Consider
  making `sudtanj/honeygain` private on Docker Hub.

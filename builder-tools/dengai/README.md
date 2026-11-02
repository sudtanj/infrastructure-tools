# dengai

> Part of a multi-image repo - see the [root README](../README.md) for how the
> per-folder build workflow works.

[dengai](https://github.com/sudtanj/dengai) is a small Rust Steam bot for one
account:
- Steam trading-card farming.
- Key redeem.
- Free-license claims, manual and automatic (watches Steam's PICS product changes).
- A bearer-token HTTP API.

It ports the relevant parts of ArchiSteamFarm and its FreePackages plugin. The
target is an Orange Pi Zero 3 (arm64, 1 GB RAM).

Image: [`sudtanj/dengai`](https://hub.docker.com/r/sudtanj/dengai)
(linux/amd64, linux/arm64), distroless, runs as uid 65532.

## Quick start

```bash
cp .env.example .env && $EDITOR .env
docker compose -f docker-compose.hub.yml up -d     # published image
docker compose up -d --build                       # or build from source
docker logs -f dengai
```

Without `DENGAI_SHARED_SECRET`, approve the first login in the Steam mobile app.
You can also set a one-off `DENGAI_GUARD_CODE`.
After the first login, the refresh token in `/data` is enough and `DENGAI_PASSWORD` can be removed.

```bash
curl -H "Authorization: Bearer $DENGAI_API_TOKEN" http://127.0.0.1:8737/status
```

All options and API endpoints: see dengai's
[README](https://github.com/sudtanj/dengai#configuration).

## Building

The Dockerfile fetches the source and cross-compiles on the build platform, so
the Rust compile runs without QEMU. `DENGAI_REF` pins a tag or branch.

## Network exposure

The API binds `0.0.0.0` inside the container. Compose publishes it on
`127.0.0.1` only. To reach it remotely, publish it on the Tailscale IP. The
`/data` volume holds a long-lived Steam login: keep it private.

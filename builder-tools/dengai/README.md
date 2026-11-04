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

## Orange Pi

[`bash-scripts/init-dengai.sh`](../../bash-scripts/init-dengai.sh) does the same with
tighter limits (64 MB, 0.5 CPU), runnable from the Orange Pi workflow
(`orangepi-bash-script-runner`, script `init-dengai`).
Repo secrets to add: `DENGAI_USERNAME`, `DENGAI_PASSWORD`, `DENGAI_SHARED_SECRET`,
`DENGAI_API_TOKEN`, and optionally `DENGAI_BACKFILL_URL`. Remove `DENGAI_PASSWORD`
once the refresh token is saved. `DENGAI_BIND` (e.g. the Tailscale IP) overrides the
`127.0.0.1` publish address.

### Deploy safety (init-dengai.sh)

- The container runs with `--restart on-failure:5`, not `unless-stopped`, so a bad
  Steam login cannot restart-loop into an account lock. After five failed restarts it
  stays down. It also means a clean stop (or a host reboot after one) does not bring it
  back by itself: rerun the workflow.
- Pin the image instead of following `:latest`: `DENGAI_IMAGE=sudtanj/dengai:v0.1.2`.
  The publish workflow pushes `:latest` and `:vX.Y.Z` (the git tag is `dengai-vX.Y.Z`,
  the Docker tag drops the `dengai-` prefix).
- Rollback: the running image is tagged `dengai:previous` before the pull. If the new
  container is not running with zero restarts after 30 s, the script starts
  `dengai:previous` with the same settings and fails the run. The old image is deleted
  only after the new one passes.
- The `dengai.config` container label is a salted hash. The salt is created once at
  `/var/lib/dengai-deploy/salt` (0600, root).
- Values containing a newline are rejected. Log output masks the secret values.

## Rebuilding on dengai pushes

The publish workflow resolves dengai's `HEAD` with `git ls-remote` and builds with
`DENGAI_REF=<sha>`, so every build is pinned and the image carries
`org.opencontainers.image.revision`. A push to the dengai repo does not trigger it yet.
To do that, add a step to dengai's CI:

```bash
gh workflow run builder-tools-docker-publish.yml -R sudtanj/infrastructure-tools -f folder=dengai
```

It needs a secret in the dengai repo (for example `INFRA_DISPATCH_TOKEN`): a fine-grained
PAT on `sudtanj/infrastructure-tools` with Actions: read and write, exported as `GH_TOKEN`.

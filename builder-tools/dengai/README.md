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

First-time setup, no Steam password in any config:

1. Set `DENGAI_API_TOKEN` (at least 12 characters, `openssl rand -hex 24`). On the Orange Pi,
   add it as a repo secret.
2. Start dengai (`docker compose ... up -d`, or run `init-dengai`).
3. Open the setup page. With no saved session and no `DENGAI_PASSWORD`, dengai waits in
   `needs_login` and serves it at `GET /` on port 8737. It asks for the API token.
   - SSH tunnel: `ssh -L 8737:127.0.0.1:8737 <board>`, then <http://127.0.0.1:8737/>.
   - Tailscale: set `DENGAI_BIND` to the tailnet IP and open `http://<tailnet-ip>:8737/`.
4. Enter the username, password and Steam Guard code there. A guard code no longer has to
   survive a GitHub deploy. The session and username are kept in `/data`.

A `shared_secret` can be entered on the page too, so later re-logins need no code.

`DENGAI_USERNAME`, `DENGAI_PASSWORD`, `DENGAI_SHARED_SECRET` and `DENGAI_GUARD_CODE` still work
for headless use, but are optional and not recommended: they put the credentials in your secrets.

```bash
cp .env.example .env && $EDITOR .env
docker compose -f docker-compose.hub.yml up -d     # published image
docker compose up -d --build                       # or build from source
docker logs -f dengai
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
Required repo secret: `DENGAI_API_TOKEN` (the script fails without it). Optional: `DENGAI_BACKFILL_URL`,
and for headless logins only `DENGAI_USERNAME`, `DENGAI_PASSWORD`, `DENGAI_SHARED_SECRET`,
`DENGAI_GUARD_CODE`. After a run, the script prints the SSH tunnel hint for the setup page.
`DENGAI_BIND` (e.g. the Tailscale IP) overrides the `127.0.0.1` publish address.

### Deploy safety (init-dengai.sh)

- The container runs with `--restart on-failure:5`, not `unless-stopped`, so a bad
  Steam login cannot restart-loop into an account lock. After five failed restarts it
  stays down. It also means a clean stop (or a host reboot after one) does not bring it
  back by itself: rerun the workflow.
- Pin the image instead of following `:latest`: `DENGAI_IMAGE=sudtanj/dengai:v0.1.4`.
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

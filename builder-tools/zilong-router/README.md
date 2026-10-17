# zilong-router

> Part of a multi-image repo - see the [root README](../README.md) for how the
> per-folder build workflow works.

[zilong-router](https://github.com/sudtanj/zilong-router) is a Rust port of
[9router](https://github.com/decolua/9router): one OpenAI- and
Anthropic-compatible endpoint in front of many LLM providers, with
multi-account fallback, usage tracking and the 9router dashboard. It keeps
9router's SQLite schema, API-key format and environment variables. The
target is an Orange Pi Zero 3 (arm64, 1 GB RAM).

Image: [`sudtanj/zilong-router`](https://hub.docker.com/r/sudtanj/zilong-router)
(linux/amd64, linux/arm64), distroless, runs as uid 65532.

## Quick start

```bash
cp .env.example .env && $EDITOR .env
docker compose -f docker-compose.hub.yml up -d     # published image
docker compose up -d --build                       # or build from source
```

Open `http://<host>:20129/dashboard` (password: `INITIAL_PASSWORD`), add
provider connections and an API key, then point clients at
`http://<host>:20129/v1` (OpenAI) or `http://<host>:20129` (Anthropic).

On the Orange Pi, [`bash-scripts/init-zilong-router.sh`](../../bash-scripts/init-zilong-router.sh)
does the same with tighter limits (runnable from the Orange Pi workflow).

## Configuration

| Variable | Default | |
|---|---|---|
| `PORT` | `20128` | listen port |
| `INITIAL_PASSWORD` | `123456` | dashboard password until one is saved |
| `JWT_SECRET` | generated | session signing secret |
| `REQUIRE_API_KEY` | `false` | require a key even from loopback |
| `TURSO_DATABASE_URL` / `TURSO_AUTH_TOKEN` | - | mirror the database to Turso |
| `TURSO_ONLY` | `0` | no database file: SQLite in RAM, Turso is the only copy |
| `TURSO_SYNC_SECS` | `60` | push interval to Turso |
| `ZILONG_ROUTER_WORKERS` | `1` (image) | tokio worker threads |
| `LOG_LEVEL` | `info` | tracing filter |
| `HTTPS_PROXY` | - | outbound proxy for provider calls |

Data lives in `/data` (`db/data.sqlite`, `jwt-secret`). With `TURSO_ONLY=1`
nothing needs persisting; mount a tmpfs there instead of a volume.

## Building

The Dockerfile clones the source and cross-compiles on the build platform
(no QEMU for the Rust compile). `ZILONG_ROUTER_REF` pins a tag or branch.

## Network exposure

Compose and `bash-scripts/init-zilong-router.sh` publish the port on `127.0.0.1`
only, so the router is not reachable from the LAN by default. To reach it
remotely, publish on a specific address instead of opening every interface:
the Tailscale IP (`ZILONG_ROUTER_BIND=$(tailscale ip -4)`) or `tailscale serve`.
Inside the container the router binds `0.0.0.0`; only the published host
address matters. Requests through Docker's bridge do not count as loopback, so
the dashboard login and API keys are always enforced.

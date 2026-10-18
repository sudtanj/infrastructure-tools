# kongming

Docker image for [sudtanj/kongming](https://github.com/sudtanj/kongming): a small self-improving agentic AI daemon (nanobot-style web UI, Telegram, remote MCP with token/OAuth, agent roles with delegation, skills + memory) built for the Orange Pi Zero 3. All state is on Turso, so the image is read-only and has **no volume**.

- Image: `sudtanj/kongming` (`linux/amd64`, `linux/arm64`), glibc binary on `distroless/cc`, runs as uid 65532.
- Port: `18800`. UI at `/`, health at `/health`, API under `/api`, WebSocket `/ws`.
- Memory: ~20–40 MB RSS idle on arm64; `96m` is a comfortable cap.

## Run

```bash
cp .env.example .env   # fill in Turso + LLM + password
docker compose -f docker-compose.hub.yml up -d
```

Or on the board: `bash-scripts/init-kongming.sh` (idempotent; used by the Orange Pi runner workflow with the `KONGMING_*` secrets).

## Build args

| Arg | Default | Meaning |
|---|---|---|
| `KONGMING_REF` | `main` | git ref of sudtanj/kongming to build |
| `RUST_IMAGE` | `rust:1-bookworm` | builder image |
| `RUNTIME_IMAGE` | `gcr.io/distroless/cc-debian12:nonroot` | runtime image |

## Environment

See the [kongming README](https://github.com/sudtanj/kongming#run) for the full table. Required: `KONGMING_TURSO_DATABASE_URL`, `KONGMING_TURSO_AUTH_TOKEN`. Strongly recommended: `KONGMING_PASSWORD`, `KONGMING_SECRET`. The LLM provider and Telegram are set up in the dashboard.

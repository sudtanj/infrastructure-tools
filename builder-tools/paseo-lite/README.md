# paseo-lite

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works. Everything below is scoped
> to this folder; run these commands from inside it (`cd paseo-lite` first).

[**paseo-lite**](https://github.com/sudtanj/paseo-code-rust) - a Rust rewrite
of the [Paseo](https://github.com/getpaseo/paseo) daemon for low-spec hosts -
with the **native** [Claude Code CLI](https://docs.claude.com/en/docs/claude-code)
and the **native** [Codex CLI](https://github.com/openai/codex), on Alpine.
No Node.js in the image. Same env vars, volumes and BYOK wiring as
[`paseo-codex`](../paseo-codex/), so you can switch between the two by
changing the image name.

## Why use this instead of `paseo-codex`

| | paseo-codex | paseo-lite |
|---|---|---|
| Base | `ghcr.io/getpaseo/paseo` (Debian + Node.js) | `alpine` |
| Daemon | Node.js Paseo daemon | ~1-2 MB static Rust binary, one thread |
| Agent CLIs | npm packages run on Node | native Claude Code + native (Rust, musl) Codex |
| Codex processes | one `codex app-server` per agent | **one shared** app-server for every project; exits when idle |
| Claude processes | one per agent, alive for the agent's life | started per prompt, kept warm 90 s, then released; max 3 at once (`PASEO_CLAUDE_MAX_LIVE`) |
| Relay / pairing | Paseo relay | same Paseo relay (`relay.paseo.sh`), same E2EE pairing link/QR |
| UI | full Paseo web UI | built-in lightweight web UI at `:6768`; official Paseo apps via relay for the core agent flow (best-effort, see the [paseo-lite README](https://github.com/sudtanj/paseo-code-rust#protocol-compatibility)) |

Idle cost is the daemon alone: no agent process runs until you send a
prompt, and adding projects costs nothing until an agent runs a turn.

## Quick start with docker compose

- **`docker-compose.yml`** - builds the image locally from the `Dockerfile`.
- **`docker-compose.hub.yml`** - pulls (published for `linux/amd64` only, see `.platforms`)
  [`sudtanj/paseo-lite`](https://hub.docker.com/r/sudtanj/paseo-lite) instead.

**All configuration lives directly in the compose YAML** (`environment:`
block). No `.env` / `env_file:` is used; `.env.example` only documents the
same variables.

```bash
# Edit the `environment:` block first - at minimum set PASEO_PASSWORD and
# Claude/Codex auth (see below).
docker compose up -d                              # build locally
docker compose -f docker-compose.hub.yml up -d    # or pull the published image

docker compose logs paseo-lite                    # pairing QR + link (relay)
```

The web UI is at `http://<host>:6768`. The current directory is mounted
at `/workspace` for agents to work in. `/home/paseo` (paseo-lite state and
pairing key, `~/.claude`, `~/.codex`) persists in the `paseo-home` volume.

To pair a phone or app.paseo.sh, scan the QR / open the link printed in the
logs on first start. Print it again with:

```bash
docker compose exec -u paseo paseo-lite paseo-lite pair
```

## Environment variables

Identical to `paseo-codex`:

| Variable | Purpose |
|---|---|
| `PASEO_PASSWORD` | password for direct (non-relay) connections - set it for anything network-reachable |
| `PASEO_LISTEN` | bind address, default `0.0.0.0:6768` (not 6767, so it can run next to `paseo-codex`) |
| `PASEO_HOSTNAMES` | extra DNS names for the Host check (`paseo.example.com,.lan`); IPs and localhost always allowed |
| `PASEO_RELAY_ENABLED` | `true`/`false` - Paseo E2EE relay for remote pairing |
| `PASEO_LOG_CONSOLE_LEVEL` | `debug`/`info`/`warn`/`error` |
| `PASEO_LOG_FILE_*` | accepted for parity; ignored (logs go to stdout) |
| `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code auth (or run `claude /login` once in the container) |
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` | Claude Code BYOK |
| `OPENAI_API_KEY` | Codex auth (seeded into `~/.codex/auth.json` on first start) |
| `CODEX_BASE_URL`, `CODEX_API_KEY`, `CODEX_MODEL` | Codex BYOK (Responses API endpoints only) - written to `~/.codex/config.toml` by `configure-codex-provider.sh` |
| `GH_TOKEN` / `GITHUB_TOKEN` | `gh` + git credential helper for private repos |
| `GH_USERNAME`, `GH_EMAIL` | global git identity (`user.name` / `user.email`) set at every start so agent commits are attributed to you; the email defaults to `<username>@users.noreply.github.com`. `gh` is also set to `git_protocol=https` with prompts disabled |

paseo-lite extras (optional): `PASEO_CLAUDE_MAX_LIVE` (3),
`PASEO_CLAUDE_IDLE_SECS` (90), `PASEO_CODEX_IDLE_SECS` (300),
`PASEO_RELAY_ENDPOINT` (`relay.paseo.sh:443`).

Interactive logins run as the `paseo` user:

```bash
docker compose exec -u paseo paseo-lite claude      # then /login
docker compose exec -u paseo paseo-lite codex login
```

## Build args

| Arg | Default | |
|---|---|---|
| `PASEO_LITE_REF` | `main` | git ref of `sudtanj/paseo-code-rust` to build |
| `CLAUDE_CODE_VERSION` | `latest` | `stable`, `latest` or exact version (official installer) |
| `CODEX_VERSION` | `latest` | `latest` or exact release (`0.46.0` -> `rust-v0.46.0`) |
| `GH_VERSION` | `2.63.2` | GitHub CLI release |
| `INSTALL_CLAUDE` / `INSTALL_CODEX` | `1` | set to `""` to leave an agent out |
| `ALPINE_VERSION` | `3.20` | base image |

The image includes the tools agents need for real work: `bash`, `git`,
`openssh-client`, `ripgrep`, and the C++ runtime the Claude binary links
against. Nothing else (no curl, no Node, no Python). Install extra tooling
in a child image if your projects need it.

## GCP free tier

Same tuning as `paseo-codex`: 800 MB container cap with 2 GB swap,
json-file log rotation, host networking, agents launched at `nice 19`. Run
`sudo scripts/gcp-free-tier-setup.sh` once on the host for the swapfile,
`vm.swappiness=20` and journald cap. With the daemon at a few MB, nearly the
whole budget goes to agent processes. Lower `PASEO_CLAUDE_MAX_LIVE` to `1` on
an e2-micro if several Claude turns run at once.

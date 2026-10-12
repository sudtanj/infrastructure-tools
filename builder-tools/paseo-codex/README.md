# paseo-codex

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works. Tuned for low-resource hosts such as a GCP free-tier e2-micro (see "GCP free tier" below). Everything below is scoped
> to this folder; run these commands from inside it
> (`cd paseo-codex` first if you're at the repo root).

[**Paseo**](https://github.com/getpaseo/paseo) - a daemon + bundled web UI
for running and orchestrating coding agent CLIs remotely - layered with
[**Codex CLI**](https://github.com/openai/codex), OpenAI's coding agent,
and [**Claude Code CLI**](https://docs.claude.com/en/docs/claude-code),
Anthropic's coding agent, with BYOK support for both: any
OpenAI-Responses-API-compatible endpoint for Codex, any
Anthropic-API-compatible endpoint for Claude Code.

Paseo's own published image ships no agent CLIs by default - its docs
document a child-image pattern (`FROM` the base image, `USER root`,
`npm install -g` whichever CLIs you want) that this image follows exactly,
adding only this repo's own BYOK wiring for both agents on top, entirely
through env vars.

**All configuration lives directly in the compose YAML** - the
`environment:` block of `docker-compose.yml` / `docker-compose.hub.yml`.
No `.env` file and no `env_file:` are used; edit the YAML, restart, done.

## Quick start with docker compose

Two compose files, depending on whether you want to build from this repo's
source or just run the already-published image:

- **`docker-compose.yml`** - builds the image locally from the `Dockerfile`
  in this repo. Use this if you're modifying the image itself.
- **`docker-compose.hub.yml`** - pulls
  [`sudtanj/paseo-codex`](https://hub.docker.com/r/sudtanj/paseo-codex)
  from Docker Hub instead of building. Use this if you just want to run it -
  only this file is needed (all config lives in its `environment:` block),
  no clone/build required.

```bash
# Edit the `environment:` block in the compose file first - at minimum set
# PASEO_PASSWORD and one of ANTHROPIC_API_KEY (Claude Code),
# OPENAI_API_KEY or CODEX_BASE_URL (Codex BYOK). All config lives there.

# Build locally:
docker compose up -d

# Or pull the published image instead:
docker compose -f docker-compose.hub.yml up -d
```

Paseo's web UI + API is then reachable at `http://localhost:6767`. The
current directory is mounted at `/workspace` for Claude Code/Codex sessions
to work in; `~/home/paseo` (Paseo's own state, plus `~/.claude` and
`~/.codex`) persists in the `paseo-home` named volume across restarts.

Both compose files use `network_mode: host` instead of a published port -
the container shares the host's network stack directly rather than going
through Docker's NATed bridge network. This matters if your host is
IPv6-only/IPv6-preferred: Docker's default bridge only NATs IPv4 unless you
separately configure IPv6 on the Docker daemon and the network, so outbound
requests to dual-stack hosts (like `api.github.com`, for `gh`/git operations)
can silently hang under bridge networking instead of failing fast. Under
host networking there's no separate stack to configure - the container
just uses whatever the host itself can already reach. The tradeoff is the
usual one for host networking: no port remapping/isolation, and
`PASEO_LISTEN`'s port is the actual host port.

You can also run either agent directly inside the running container, per
Paseo's own docs:

```bash
docker compose exec --user paseo paseo-codex claude
docker compose exec --user paseo paseo-codex codex
```

## Configuration (all via the compose `environment:` block)

Everything is set via environment variables declared right in
`docker-compose.yml` / `docker-compose.hub.yml` - uncomment and fill in
what you need, then `docker compose up -d` to apply. No `.env` file, no
`env_file:`, no image rebuild needed for config changes.

| Variable | Purpose |
|---|---|
| `PASEO_PASSWORD` | Auth for Paseo's daemon/web UI. Strongly recommended for anything network-reachable. |
| `PASEO_LISTEN` | Listen address (default `0.0.0.0:6767`). |
| `PASEO_HOSTNAMES` | Comma-separated allow-listed hostnames, for use behind a reverse proxy. |
| `ANTHROPIC_API_KEY` | Direct Anthropic API key for Claude Code - **API-key billing only; leave unset if you use a Pro/Max subscription**. |
| `CLAUDE_CODE_OAUTH_TOKEN` | Subscription auth for headless/remote use - from `claude setup-token` on your own machine; charges your plan, not API usage. Alternative to `claude /login`. |
| `ANTHROPIC_BASE_URL` | Claude Code BYOK: point Claude Code at your own Anthropic-API-compatible endpoint instead of `api.anthropic.com`. |
| `ANTHROPIC_AUTH_TOKEN` | Optional bearer token for the BYOK endpoint (sent as `Authorization: Bearer` instead of `x-api-key`). |
| `ANTHROPIC_MODEL` | Optional default model for Claude Code (unset = its built-in default). |
| `OPENAI_API_KEY` | Direct OpenAI API key - passed straight through to Codex sessions Paseo launches. |
| `CODEX_BASE_URL` | Codex BYOK: point Codex at your own OpenAI-Responses-API-compatible endpoint instead of `api.openai.com`. |
| `CODEX_API_KEY` | Optional key for the BYOK endpoint (a local/trusted gateway needs none). |
| `CODEX_MODEL` | Optional default model for Codex. |
| `GH_TOKEN` | GitHub token for cloning/pulling private repos into `/workspace` - wired up for both `gh` and plain `git` automatically. |

### How Claude Code gets its config

Claude Code reads its settings natively from the environment on every
launch - `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_MODEL` - so unlike Codex there is no config file for the
entrypoint to generate at startup. The entrypoint just hands this
environment to Paseo's daemon, which passes those vars straight to the
Claude Code sessions it launches.

**Subscription (Pro/Max) works out of the box** - nothing in this image
forces API-key auth (no key, no placeholder; `ANTHROPIC_API_KEY` stays
unset by default, and it would take precedence if you ever set it). Two
ways to authenticate with your plan:

1. **Interactive login (simplest)** - run `claude /login` once inside the
   container (`docker compose exec --user paseo paseo-codex claude`, then
   `/login`); the OAuth credentials are stored in `~/.claude`, which
   persists in the `paseo-home` volume across restarts, and the startup
   chown keeps them writable by the `paseo` user.
2. **Headless token** - run `claude setup-token` on your own machine (it
   walks you through the OAuth flow and prints a token for your
   subscription) and put it in the compose `environment:` block as
   `CLAUDE_CODE_OAUTH_TOKEN`. Nothing is written to disk in the container.

Either way Claude Code bills/limits against your subscription, not
per-token API usage. Only set `ANTHROPIC_API_KEY` if you actually want
API-key billing.

### Codex BYOK caveat

Codex CLI only speaks the newer **Responses API** (`/v1/responses`), not
the more common Chat Completions format that most third-party
"OpenAI-compatible" gateways implement. Your `CODEX_BASE_URL` endpoint has
to actually support the Responses API, or requests will fail even though
Codex itself starts fine.

### IPv4-broken / IPv6-only hosts: reaching GitHub via NAT64

GitHub's own hosts (`github.com`, `api.github.com`) don't publish AAAA
records - they're IPv4-only. If your host has working IPv6 but a
broken/unavailable IPv4 path (a dead default route, or an ISP/VPS that only
actually passes v6 despite handing out an IPv4 address), `gh`, git, and
Codex will dial GitHub's real IPv4 address directly and hang until it times
out - `network_mode: host` alone doesn't fix this, since the container is
then just as IPv4-broken as the host it shares a network stack with.

The fix is DNS64 + NAT64: point DNS at a resolver that synthesizes an IPv6
address for IPv4-only hosts, backed by a NAT64 gateway that translates the
traffic back to the real IPv4 destination. Cloudflare runs a public one -
uncomment the `dns:` block in `docker-compose.yml`/`.hub.yml`:

```yaml
dns:
  - 2606:4700:4700::64
  - 2606:4700:4700::6400
```

Leave it commented on a normal dual-stack or IPv4-only host - it's specifically for this IPv6-only-egress case.

### Cloning private repos

Set `GH_TOKEN` (a GitHub personal access token with `repo`/`contents:read`
scope) and both `gh` subcommands and plain `git clone`/`git pull` of
private repos work out of the box inside `/workspace` - no SSH keys or
manual `gh auth login` needed.

## How it's built

`Dockerfile` starts `FROM ghcr.io/getpaseo/paseo:latest`, installs
`@anthropic-ai/claude-code` and `@openai/codex`, plus GitHub CLI (`gh`,
from GitHub's own apt repo - the base image is Debian bookworm-slim), as
root, and wraps Paseo's own entrypoint with a thin `entrypoint.sh` that
runs `configure-codex-provider.sh` (generates `~/.codex/config.toml` from
the Codex env vars above - Claude Code needs no generated config: its
`ANTHROPIC_*` vars are read straight from the compose `environment:`
block) and, if
`GH_TOKEN`/`GITHUB_TOKEN` is set, `gh auth setup-git` (wires the token into
git's credential helper) before handing off, unchanged, to Paseo's original
entrypoint - same `tini` PID-1 wrapping, same root -> `paseo`-user
privilege drop via `gosu`, same daemon-start vs. exec-passthrough
branching.

## GCP free tier (e2-micro) tuning

Defaults here target a 1 GB / shared-0.25-vCPU VM:

- **Container caps** (compose): `mem_limit: 800m`, `memswap_limit: 2g`, `cpus: 1.0`, capped Docker json logs.
- **Paseo config** (seeded on first start): MCP disabled (relay left on), browser tools off, unused providers (opencode/copilot/pi) off, Haiku for metadata generation, log file level `info` instead of `trace`, 5 MB x 2 rotation.
- **Node**: `--max-old-space-size=512`; lower to 384 if you see OOM kills.
- **Host**: run `sudo scripts/gcp-free-tier-setup.sh` once for a 2 GB swapfile, lower swappiness and capped journald.
- **Usage habits**: run one agent session at a time (each Claude/Codex CLI process can use 200-400 MB), disable the provider you don't use in `~/.paseo/config.json`, and keep voice/dictation on a remote provider (`openai`) rather than local models.
- Existing volumes keep their old `config.json`; edit it or delete it to re-seed.

### Trimming Claude Code / Codex

- Only need one agent? Build without the other: `--build-arg INSTALL_CODEX=` (or `INSTALL_CLAUDE=`). Also set that provider to `"enabled": false` in `~/.paseo/config.json`.
- The image sets Claude Code's `DISABLE_NON_ESSENTIAL_MODEL_CALLS`, `DISABLE_ERROR_REPORTING`, `DISABLE_BUG_COMMAND` and `DISABLE_COST_WARNINGS`, on top of autoupdate/telemetry off.
- Claude Code is a Node process (the 512 MB heap cap applies to each one); Codex is a native binary and is usually lighter. Prefer Codex or a smaller Claude model (`ANTHROPIC_MODEL=claude-haiku-4-5`) for routine tasks.
- Disk: Claude keeps transcripts 30 days by default; set `"cleanupPeriodDays": 7` in `~/.claude/settings.json`. For Codex, `[history] persistence = "none"` in `~/.codex/config.toml` stops saving history.

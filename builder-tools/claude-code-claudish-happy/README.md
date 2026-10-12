# claude-code-claudish-happy

> Part of a multi-image repo - see the [root README](../README.md) for how
> the generic per-folder build workflow works. Everything below is scoped
> to this folder; run these commands from inside it
> (`cd claude-code-claudish-happy` first if you're at the repo root).

A single Docker image, built on full Ubuntu 24.04, bundling two coding
agents plus mobile/web control for both, in an isolated environment that
can actually compile and run the code it writes:

- **[Claude Code](https://claude.com/claude-code)** — Anthropic's coding agent (`claude`)
- **[Codex CLI](https://github.com/openai/codex)** — OpenAI's coding agent (`codex`), with BYOK support for any OpenAI-Responses-API-compatible endpoint
- **[Happy](https://github.com/slopus/happy)** — mobile/web control for Claude Code or Codex sessions (`happy`)

Also includes a full dev toolchain: build-essential/cmake/gdb (C/C++), Python 3
+ pip/venv, Node.js 22, Deno, Go, git, sqlite3, and the usual CLI utilities
(jq, ripgrep, tmux, vim, etc.). The `agent` user has passwordless `sudo` for
ad hoc package installs. (No Rust or Java - see "Image size" below for why
and how to add them back if you need them.)

> This image previously routed non-Anthropic models through
> [Claudish](https://claudish.com) instead of Codex. That's been dropped -
> Claudish's launcher hard-requires the Bun runtime and, in practice, proved
> more fragile than just using Codex CLI's own native BYOK support directly.
> Codex CLI is a single official binary (no extra runtime dependency) and
> `happy codex` is Happy's own first-class integration, not a workaround.

## Quick start with docker compose

Two compose files, depending on whether you want to build from this repo's
source or just run the already-published image:

- **`docker-compose.yml`** - builds the image locally from the `Dockerfile`
  in this repo. Use this if you're modifying the image itself.
- **`docker-compose.hub.yml`** - pulls
  [`sudtanj/claude-code-claudish-happy`](https://hub.docker.com/r/sudtanj/claude-code-claudish-happy)
  from Docker Hub instead of building. Use this if you just want to run the
  CLIs - only this file and a `.env` are needed, no clone/build required.

```bash
cp .env.example .env
# edit .env and fill in the keys for whichever CLI you plan to run

# Build locally:
docker compose run --rm agent claude

# Or pull the published image instead - same commands, just add -f:
docker compose -f docker-compose.hub.yml run --rm agent claude
docker compose -f docker-compose.hub.yml run --rm agent codex
docker compose -f docker-compose.hub.yml run --rm agent happy claude
docker compose -f docker-compose.hub.yml run --rm agent happy codex
docker compose -f docker-compose.hub.yml run --rm agent bash
```

`docker-compose.hub.yml` pulls `:latest` and sets `pull_policy: always`, so
each run fetches whatever the CI workflow most recently published. Pin an
exact version instead (see the [tags on Docker
Hub](https://hub.docker.com/r/sudtanj/claude-code-claudish-happy/tags)) if
you want reproducible pulls that don't change under you.

The entrypoint checks that the environment variables your chosen command
needs are actually set (from `.env`, `environment:` in `docker-compose.yml`,
or `docker run -e ...`) and fails fast with a clear message if one is
missing, rather than letting the CLI hang on a login prompt.

| Command | Required env var(s) |
|---|---|
| `claude` | `ANTHROPIC_API_KEY` |
| `codex` | `OPENAI_API_KEY`, or `CODEX_BASE_URL` for BYOK |
| `happy claude` | `ANTHROPIC_API_KEY` |
| `happy codex` | `OPENAI_API_KEY`, or `CODEX_BASE_URL` for BYOK |

See `.env.example` for the full list, and `docker-compose.yml` for where to
put them for compose runs.

### Codex BYOK: custom OpenAI-Responses-API-compatible endpoint

Point Codex at your own gateway (Azure OpenAI, LiteLLM, a corporate proxy,
...) instead of `api.openai.com`, via:

- `CODEX_BASE_URL` (required to do anything here)
- `CODEX_API_KEY` (optional - a local/trusted gateway needs no key at all;
  omitted means no auth header is sent)
- `CODEX_MODEL` (optional - sets the default model)

On startup the entrypoint writes these into a clearly-delimited managed
block in `~/.codex/config.toml` (Codex's own `[model_providers.custom]`
mechanism), merged with - not replacing - anything else already in that
file, so it's safe to run every start even with the `codex-config` volume
persisted. Use it with:

```bash
docker compose run --rm agent codex
docker compose run --rm agent happy codex
```

**Important caveat**: as of the Codex version this image installs, Codex
CLI only speaks the newer **Responses API** (`/v1/responses`) - the older,
far more common **Chat Completions** format (`/v1/chat/completions`) that
most third-party "OpenAI-compatible" gateways (OpenRouter, vLLM, LM Studio,
plain Ollama, ...) implement was removed upstream. Your endpoint has to
actually support the Responses API, or requests will fail even though Codex
itself starts fine and the config looks correct. Azure OpenAI and OpenAI's
own API support it; check before assuming a given gateway does.

### Connecting to Happy (pairing your phone/browser)

**Yes, Happy works with both agents** - `happy claude` and `happy codex`
are both first-class Happy commands (not something this image bolts on),
and pairing is identical either way; it's the only part that ever does the
pairing dance below.

Happy needs **no API key at all** - it authenticates by pairing a locally
generated keypair to your account, not by an env var. But this image doesn't
just let Happy's own interactive pairing happen wherever it would normally
fall (mid-startup, right before it launches the agent) - the entrypoint
detects up front whether a valid Happy credential exists and, if not, runs
pairing **on its own, before Claude Code or Codex ever start**:

1. Run `happy claude` (or `happy codex`) as normal.
2. If `~/.happy/access.key` doesn't exist yet, the entrypoint runs Happy's
   own `happy auth login` - a pairing-only subcommand that never touches
   Claude Code/Codex - instead of your actual command.
3. That prints a QR code **and** a plain URL/link (mobile app or web) to the
   terminal. Scan/open it and approve the session from the [Happy
   app](https://app.happy.engineering) or mobile app.
4. Once approved, the entrypoint prints something like:
   ```
   HAPPY_CREDENTIALS_B64=eyJ0b2tlbiI6...
   ```
   and **exits without starting Claude Code or Codex this run.**
5. Copy that line into `.env` (or `environment:` in `docker-compose.yml`),
   then re-run the exact same command - it now goes straight into your
   session, no pairing step.

That means:
- The container **must have a real terminal attached** for step 3 - use
  `docker compose run --rm agent ...` (which allocates one automatically
  when your own terminal is real) or `docker run -it`.
- If `~/.happy` (mounted here as the `happy-config` volume) already has a
  valid `access.key` - from a previous run, or because you set
  `HAPPY_CREDENTIALS_B64` - steps 2-5 are skipped entirely and your command
  runs immediately.
- **No env var is required** for a normal setup using Anthropic's hosted
  Happy server (`api.cluster-fluster.com`) and web app
  (`app.happy.engineering`) - those are just Happy's defaults; pairing works
  the same either way.
- `HAPPY_CREDENTIALS_B64` is a credential (it grants control of your
  Happy-linked sessions) - keep it out of git, same as any API key in `.env`.

Only set these if you're self-hosting Happy's own server
([`happy-server`](https://github.com/slopus/happy/tree/main/packages/happy-server))
instead of using the hosted one:

| Env var | Default | Purpose |
|---|---|---|
| `HAPPY_SERVER_URL` | `https://api.cluster-fluster.com` | Happy's sync/auth server |
| `HAPPY_WEBAPP_URL` | `https://app.happy.engineering` | Web app the pairing link opens |
| `HAPPY_HOME_DIR` | `~/.happy` | Where credentials/settings are stored |

### Running an agent in the background (access via Happy later)

There's just the one service/container (`agent`) - it's "batteries
included": its **default command already runs Claude Code (via Happy) in
the background**, so a plain `docker compose up -d` gives you a persistent
session you connect to later from the Happy app, no separate service or
extra flags needed. `docker compose run --rm agent <command>` still works
for one-off interactive use (overriding that default), same as always.

```bash
# 1. Pair Happy first (one-time, needs a real terminal - see "Connecting
#    to Happy" above). Ctrl-C once you see your prompt.
docker compose run --rm agent happy claude

# 2. Grab the credential it printed, put it in .env as HAPPY_CREDENTIALS_B64=...

# 3. Start it persistently, using the default command:
docker compose up -d
```

Under the hood, the default command runs `happy claude` inside a detached
`tmux` session (so the agent gets a real terminal to run in, whether or not
the container itself has one attached), and the container itself keeps
running indefinitely (`restart: unless-stopped`), independent of any
attached terminal. From here, connect from the Happy app whenever you
like - that's the whole point of Happy, and nothing container-specific
about it.

To peek at it locally (e.g. to check on progress, or approve a permission
prompt without your phone handy):

```bash
docker compose exec agent tmux attach -t happy
# Ctrl-b then d to detach without stopping it
```

Step 1 matters: running `docker compose up -d` before Happy is paired hits
the same pairing prompt, but with nobody watching the pane - it prints the
QR/link and exits almost immediately (the container stays up thanks to
`restart: unless-stopped`, but the tmux session is just an empty dead pane
until you attach, pair manually, and restart it, or pair via step 1 and
run `docker compose up -d --force-recreate` instead). Pairing once first
avoids that.

Want Codex running in the background instead of Claude Code? Override the
command in `docker-compose.yml`:

```yaml
    command: ["background", "happy", "codex"]
```

(and make sure `OPENAI_API_KEY` or `CODEX_BASE_URL` is set in `.env`), then
`docker compose up -d`.

#### Deploying on Portainer (or any orchestrator that never attaches a terminal)

The compose file requests no pty/stdin anywhere (see the comment above the
`command:` line) and its default command is already the background one
above - so it's deployable as-is with `docker stack deploy` / Portainer's
"Stacks" feature / `docker compose up -d`, with zero interactive input
required at deploy time. Everything it needs comes from environment
variables:

1. **Pair Happy somewhere that has a real terminal first** - your own
   machine, a `docker compose run --rm agent happy claude` locally, or
   Portainer's own container "Console" feature (which *does* give you an
   interactive shell into a running container, separately from the stack's
   own deploy-time config) to run `happy auth login` by hand. Either way,
   you're only after the `HAPPY_CREDENTIALS_B64` value it prints - see
   "Connecting to Happy" above. This one step can't be made non-interactive
   (Happy's pairing is inherently an approve-from-your-phone-or-browser
   flow), but it only has to happen once, and not on Portainer itself.
2. In Portainer's stack environment variables (or your `.env`), set
   `HAPPY_CREDENTIALS_B64` plus whichever provider key the default command
   needs (`ANTHROPIC_API_KEY` for `happy claude`, or e.g. `OPENAI_API_KEY`/
   `CODEX_BASE_URL` if you changed the command to `happy codex` as above).
3. Deploy the stack. The container starts, seeds the Happy credential from
   the env var, skips pairing entirely, and runs headless from then on
   (`restart: unless-stopped`). Connect from the Happy app whenever.

## Build

```bash
docker build -t claude-code-claudish-happy .
```

## Run

Mount your project into `/workspace` and pass whichever CLI you want as the command.

Plain Claude Code (needs a real Anthropic key):

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  claude-code-claudish-happy claude
```

Codex CLI, direct OpenAI API:

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e OPENAI_API_KEY=sk-... \
  claude-code-claudish-happy codex
```

Codex CLI via BYOK, against your own OpenAI-Responses-API-compatible endpoint:

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e CODEX_BASE_URL=https://my-gateway.internal/v1 \
  -e CODEX_API_KEY=sk-... \
  claude-code-claudish-happy codex
```

Claude Code wrapped by Happy, for mobile/web control:

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e ANTHROPIC_API_KEY=sk-ant-... \
  claude-code-claudish-happy happy claude
```

Codex wrapped by Happy instead:

```bash
docker run -it --rm \
  -v "$PWD":/workspace \
  -e OPENAI_API_KEY=sk-... \
  claude-code-claudish-happy happy codex
```

Drop into a shell with all the CLIs on `PATH`:

```bash
docker run -it --rm -v "$PWD":/workspace claude-code-claudish-happy bash
```

## Notes

- The image sets a placeholder `ANTHROPIC_API_KEY` so Claude Code's login dialog
  doesn't block when you're not using Anthropic directly; override it with a
  real key for direct Anthropic use.
- Runs as a non-root user (`agent`) with `/workspace` as the working directory.
- On every start, the entrypoint `sudo chown`s `~/.claude`, `~/.codex`, and
  `~/.happy` back to the `agent` user before doing anything else. Their
  named volumes can end up root-owned - e.g. a volume that already existed
  from an older image build, before this image's non-root user was set up
  the way it is now - and the Dockerfile's own `chown` at build time only
  ever affects the image layer, not a volume mounted over that path later.
  Without this, a stale volume silently produces `EACCES: permission
  denied` the first time a CLI tries to write there.

## Image size

Originally ~2.5GB with a full toolchain (C/C++, Python, Go, Rust, Deno,
Node, a JDK). Rust and Java have since been dropped (this image only keeps
Go, Deno, and Python as language runtimes, alongside the C/C++ toolchain
that `npm install`'s native addons and Python's C extensions rely on),
saving roughly **~877MB**:

- **Rust** (rustc + cargo + rust-std, rustup's minimal profile): measured by
  downloading the actual release components - **~577MB**.
- **Java** (`default-jdk-headless` + its full dependency closure -
  `openjdk-*-jre-headless`, `openjdk-*-jdk-headless`, etc.): computed from
  the real apt dependency closure - **~300MB**.

That put the image around **~1.6-1.7GB**. Swapping Claudish (+ the Bun
runtime it required, ~76MB) for Codex CLI's own native binary (~323MB, per
`npm view`) added roughly **+250MB** back, since Codex's binary is
substantially larger than Bun + Claudish combined - putting the image
around **~1.9-2.0GB**. What's in it, roughly:

1. **Claude Code's native binary, installed twice** (~220MB each, ~440MB
   total) - once directly (`@anthropic-ai/claude-code`, used by `claude`),
   and once again bundled inside Happy's own copy
   (`@anthropic-ai/claude-agent-sdk`, which Happy launches instead of the
   global `claude`). This is architecturally how Happy works and isn't
   something the Dockerfile can dedupe.
2. **Codex CLI's native binary** (~323MB) - unlike Claude Code, Happy spawns
   the system `codex` directly (no bundled duplicate), so this one isn't
   doubled.
3. **Go** (~350MB) and **Deno** (~120MB), the two remaining language
   runtimes, plus **Node.js** (~180MB, required to run the npm-based CLIs
   themselves - not optional).
4. The base OS + C/C++ toolchain (build-essential, cmake, gdb, etc.) and
   everyday CLI utilities.

Already-applied, no-functionality-cost trims: `locales` package dropped in
favor of glibc's built-in `C.UTF-8`, and ~86MB of dead weight removed from
Happy's own package - it bundles prebuilt ripgrep + difftastic binaries for
all 6 platform combinations it supports (darwin/linux/win32 x x64/arm64)
directly in its files rather than as npm optionalDependencies, so a plain
`npm install` pulls all 12 archives regardless of host platform; the
Dockerfile deletes the 10 this Linux container can never use, in the same
build layer they're installed in (so they don't just become invisible -
they're actually gone from the image).

Investigated and ruled out: switching the base image (`ubuntu:24.04` is
already ~28MB compressed, essentially identical to `debian:bookworm-slim`'s
~27MB - not a meaningful lever either way) and multi-stage builds (their
whole value is discarding a build-only toolchain from the final image; this
image *is* the toolchain - Go/Deno/Python have to stay in the final image
for Claude Code to use them at runtime, so there's nothing to discard).

Need Go, Deno, or the C/C++ toolchain back out too? Each remaining
toolchain is still a self-contained block in the Dockerfile - ask if you'd
like help trimming further.

## CI/CD: auto-publish to Docker Hub

[`.github/workflows/docker-publish.yml`](.github/workflows/docker-publish.yml)
builds and pushes this image to Docker Hub as
[`sudtanj/claude-code-claudish-happy`](https://hub.docker.com/r/sudtanj/claude-code-claudish-happy),
for **both `linux/amd64` and `linux/arm64`**, on every push to the tracked
branch(es). Each run:

1. **`tag` job** - auto-bumps a semver git tag (patch by default, via
   [`anothrNick/github-tag-action`](https://github.com/anothrNick/github-tag-action)).
2. **`build` job** (matrix: one runner per arch) - builds each architecture
   **natively** (amd64 on a regular runner, arm64 on GitHub's native arm64
   runner - no QEMU emulation, which this image's full dev toolchain would
   make painfully slow) and pushes each as an untagged image, by digest.
3. **`merge` job** - combines both digests into a single multi-arch manifest
   and pushes it as both `:latest` and `:<the new tag>` (e.g. `:v1.2.4`) -
   `docker pull` picks the right architecture automatically.

**One-time setup before this will actually run:**

1. Add a repo secret (Settings -> Secrets and variables -> Actions):
   - `DOCKER_HUB_KEY` - a Docker Hub access token with Read & Write scope
     (Docker Hub -> Account Settings -> Security -> Personal access tokens)

   The Docker Hub username (`sudtanj`) is hardcoded in the workflow rather
   than kept as a secret, since it isn't sensitive.
2. Give the workflow's default token push access so the auto-tag step can
   push new tags: Settings -> Actions -> General -> Workflow permissions ->
   "Read and write permissions".
3. Make sure GitHub-hosted arm64 runners (the `ubuntu-24.04-arm` label) are
   available to this repo - free for public repos; on a private repo it
   needs a plan that includes them. If that label isn't available, replace
   the arm64 entry's `runner:` in the `build` job's matrix with
   `ubuntu-latest` and add a `docker/setup-qemu-action` step - it'll still
   work, just much slower (QEMU-emulated).

The workflow triggers on pushes to `main`.

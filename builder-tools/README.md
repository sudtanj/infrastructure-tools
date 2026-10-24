# builder-tools

> Migrated from [sudtanj/builder-tools](https://github.com/sudtanj/builder-tools) into this repo. Its workflows now live in `../.github/workflows/builder-tools-*.yml` (GitHub only reads workflows from the repo root) and are scoped to this folder.

A generic builder-tools monorepo: per-folder Docker image builds, plus standalone auto-updating builders (see "Non-Docker projects"). Every top-level folder in this
repo that contains a `Dockerfile` is an independent image: its own Docker
Hub repository, its own version tag sequence, built and published only when
that folder actually changes.

## How it works

[`builder-tools-docker-publish.yml`](../.github/workflows/builder-tools-docker-publish.yml)
runs on every push to `main`:

1. **`discover`** - diffs the push (`git diff <before> <after>`) to find
   which top-level folders changed, then keeps only the ones that contain a
   `Dockerfile`. A brand-new branch (nothing to diff against) or a manual
   run with no folder specified builds every folder that has one.
2. **`build`** (one job per detected folder, run in parallel) - for each:
   - Bumps that folder's own version tag: a git tag named `<folder>-vX.Y.Z`,
     found by listing existing `<folder>-v*` tags and incrementing the
     patch number (starts at `v0.1.0` if the folder has never been tagged).
     Every folder's tag sequence is independent - `foo-v3.2.1` and
     `bar-v0.4.0` don't affect each other.
   - Builds `./<folder>` for `linux/amd64` and `linux/arm64` (via QEMU -
     simple and uniform across every folder, at the cost of a slower arm64
     build than native arm64 runners would give; fine unless a folder's
     build is unusually heavy).
   - Pushes to Docker Hub as `sudtanj/<folder-name>:latest` and
     `sudtanj/<folder-name>:<the new version>`.

Touching only `paseo-codex/` triggers only that image's
build; adding a new `my-image/Dockerfile` and pushing triggers only
`my-image`'s first build (`my-image-v0.1.0`), untouched folders are left
alone.

## Adding a new image

1. Create a new top-level folder with a `Dockerfile` in it - that's the
   only requirement. [`paseo-codex/`](paseo-codex/)
   is a full worked example (its own `README.md`, `docker-compose.yml` /
   `docker-compose.hub.yml`, `.env.example`, entrypoint scripts, ...), but
   none of that is required by the workflow itself - it only ever looks
   for the `Dockerfile`.
2. Push to `main`. The next run detects the new folder and publishes
   `sudtanj/<folder-name>:v0.1.0` (+ `:latest`) automatically.

## Building manually

Via the Actions tab, or:

```bash
# Build every folder that has a Dockerfile:
gh workflow run builder-tools-docker-publish.yml

# Build just one folder (e.g. to force a rebuild without changing anything):
gh workflow run builder-tools-docker-publish.yml -f folder=paseo-codex
```

## One-time setup

1. Add a repo secret (Settings -> Secrets and variables -> Actions):
   - `DOCKER_HUB_KEY` - a Docker Hub access token with Read & Write scope
     (Docker Hub -> Account Settings -> Security -> Personal access
     tokens). Used for every image in this repo; the Docker Hub username
     (`sudtanj`) is hardcoded in the workflow since it isn't sensitive.
2. Give the workflow's default token write access so it can push the
   per-folder version tags: Settings -> Actions -> General -> Workflow
   permissions -> "Read and write permissions".

## Automatic updates

Dependabot checks each Dockerfile weekly and auto-merges newer base-image tags
after the PR checks pass. The publish workflow also rebuilds every image every
Monday at 04:17 UTC with `--no-cache`, refreshing rolling tags even when the
Dockerfile text is unchanged. Enable repository auto-merge and protect `main`.

## Images in this repo

| Folder | Docker Hub | What it is |
|---|---|---|
| [`paseo-codex/`](paseo-codex/) | [`sudtanj/paseo-codex`](https://hub.docker.com/r/sudtanj/paseo-codex) | [Paseo](https://github.com/getpaseo/paseo) (remote daemon + web UI) + Codex CLI + Claude Code CLI, BYOK via env vars in the compose YAML, tuned for low-resource hosts (GCP free-tier e2-micro: memory/CPU caps, log rotation, optional agent CLIs) - see its own [README](paseo-codex/README.md) |
| [`paseo-lite/`](paseo-lite/) | [`sudtanj/paseo-lite`](https://hub.docker.com/r/sudtanj/paseo-lite) | [paseo-lite](https://github.com/sudtanj/paseo-code-rust) (Rust Paseo daemon, Paseo relay compatible) + native Claude Code CLI + native Codex CLI on Alpine, no Node.js; one shared Codex app-server and pooled Claude processes across all projects; same env vars as `paseo-codex` - see its own [README](paseo-lite/README.md) |
| [`oci-freetier-creator/`](oci-freetier-creator/) | [`sudtanj/oci-freetier-creator`](https://hub.docker.com/r/sudtanj/oci-freetier-creator) | Runs [oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation) unattended, config via env vars - see its own [README](oci-freetier-creator/README.md) |
| [`zilong-router/`](zilong-router/) | [`sudtanj/zilong-router`](https://hub.docker.com/r/sudtanj/zilong-router) | [zilong-router](https://github.com/sudtanj/zilong-router): Rust port of 9router - one OpenAI- and Anthropic-compatible endpoint with multi-account fallback, usage tracking, the 9router dashboard and optional Turso storage - see its own [README](zilong-router/README.md) |
| [`honeygain/`](honeygain/) | [`sudtanj/honeygain`](https://hub.docker.com/r/sudtanj/honeygain) | Official Honeygain client repackaged on distroless (amd64 + arm64); credentials from `.env`, `-tou-accept` always on - see its own [README](honeygain/README.md) |
| [`traffmonetizer/`](traffmonetizer/) | [`sudtanj/traffmonetizer`](https://hub.docker.com/r/sudtanj/traffmonetizer) | Official Traffmonetizer client on distroless static, non-root, real multi-arch (amd64 + arm64); token from `.env` - see its own [README](traffmonetizer/README.md) |
| [`earnfm/`](earnfm/) | [`sudtanj/earnfm`](https://hub.docker.com/r/sudtanj/earnfm) | Official EarnFM client on distroless static, non-root, Go runtime capped to the container (amd64 + arm64); token from `.env` - see its own [README](earnfm/README.md) |
| [`repocket/`](repocket/) | [`sudtanj/repocket`](https://hub.docker.com/r/sudtanj/repocket) | Official Repocket client on distroless cc, non-root instead of forced root (amd64 + arm64); API key from `.env` - see its own [README](repocket/README.md) |
| [`pawns/`](pawns/) | [`sudtanj/pawns`](https://hub.docker.com/r/sudtanj/pawns) | Official Pawns (IPRoyal) client on distroless static, non-root (amd64 + arm64); login from `.env`, Sentry reporter disabled - see its own [README](pawns/README.md) |
| [`packetstream/`](packetstream/) | [`sudtanj/packetstream`](https://hub.docker.com/r/sudtanj/packetstream) | Official PacketStream client on distroless static, non-root (amd64 + arm64); runs the native binary instead of the launcher's 32-bit ARM build, self-update off - see its own [README](packetstream/README.md) |
| [`bitping/`](bitping/) | [`sudtanj/bitping`](https://hub.docker.com/r/sudtanj/bitping) | Official Bitping node on distroless static, non-root (amd64 + arm64); no relaunch script, self-update off, state in tmpfs - see its own [README](bitping/README.md) |
| [`xmrig/`](xmrig/) | [`sudtanj/xmrig`](https://hub.docker.com/r/sudtanj/xmrig) | [XMRig](https://github.com/xmrig/xmrig) built from the latest upstream release at every (weekly, no-cache) rebuild; amd64 + arm64. Fork of [MuRF2/xmrig.docker](https://github.com/MuRF2/xmrig.docker) - see its own [README](xmrig/README.md) |

## Non-Docker projects

Folders **without** a `Dockerfile` are ignored by the Docker publish workflow
(it also has a `paths-ignore` for these folders) and are handled by their own
workflows.

| Folder | Workflow | What it is |
|---|---|---|
| [`mi3-padavan-firmware-builder/`](mi3-padavan-firmware-builder/) | [`mi3-padavan-firmware-builder.yml`](../.github/workflows/builder-tools-mi3-padavan-firmware-builder.yml) | Builds Xiaomi Mi 3 [Padavan](https://gitlab.com/hadzhioglu/padavan-ng) firmware. Checks the upstream `stable_master` branch every 6 hours, commits the new hash to `variables` and builds when it changed (also on manual run, pushes to the folder, and `mi3-padavan-firmware-builder-v*` tags). Firmware is an artifact kept 7 days - see its [README](mi3-padavan-firmware-builder/README.md) |
| [`opi-zero3-armbian/`](opi-zero3-armbian/) | [`opi-zero3-armbian.yml`](../.github/workflows/builder-tools-opi-zero3-armbian.yml) | Minimal, locked-down [Armbian](https://github.com/armbian/build) (Debian trixie) SD card image for the Orange Pi Zero 3 that only runs Docker: no default login, key/LAN-only sshd, nftables host firewall, first-boot provisioning (user, Wi-Fi, Tailscale) from a file on the card. Tested in CI (unit, firewall-in-netns, image inspection, QEMU Zero 3 simulation incl. apt upgrades + reboot); fixes on the pinned Armbian release branch are picked up weekly and promoted only after the tests pass (new releases on request). Image is an artifact kept 14 days - see its [README](opi-zero3-armbian/README.md) |

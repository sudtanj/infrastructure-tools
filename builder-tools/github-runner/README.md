# github-runner

Self-hosted GitHub Actions runners for one repo that **never need re-authorising** and **leave nothing behind after a job**.

- Image: `sudtanj/github-runner` (`linux/amd64`, `linux/arm64`), Alpine + bash/curl/jq/openssl/docker-cli, ~64 MiB cap.
- Deployed on the GCP VM by [`bash-scripts/upsert-github-runner.sh`](../../bash-scripts/upsert-github-runner.sh) (pick `upsert-github-runner` in "Run Bash Scripts on GCP VM").

## How it works

The image is a supervisor. It never runs jobs itself:

```
loop:
  GitHub App key ──► 1h installation token (this repo, Administration only)
  delete this host's offline runners (left over from a VM stop)
  POST /actions/runners/generate-jitconfig ──► single-use runner config
  docker run ghcr.io/actions/actions-runner  (work dir + /tmp on tmpfs)
  runner takes ONE job, exits ──► container removed, RAM freed
```

**Why stopping and starting the VM needs nothing from you.** The old myoung34 setup was given a registration token, and those expire after 1 hour, so every restart needed a new one. A GitHub App private key does not expire. The supervisor creates a new single-use runner for every job, and Docker's `--restart unless-stopped` starts the supervisor again at boot (Docker's state is in `/var`, which survives reboots on COS). Runners left registered by a VM that went down are deleted on the next start.

**What is cleaned up**

| Data | Where it lives | After the job |
|---|---|---|
| Checkout, `_temp`, step secrets files, tool cache | `/home/runner/_work` on **tmpfs** | gone (RAM freed) |
| `/tmp` | tmpfs | gone |
| Runner's own config and credentials | container layer | container deleted; the runner was single-use and GitHub has already removed it |
| Anything a job writes elsewhere (`apt install`, `~/.npm`) | container layer on disk | container deleted. The files are unlinked but not overwritten, so they are readable only by root on the VM until the space is reused. GCP disks are also encrypted at rest. |
| GitHub App key | `/var/lib/gh-runner` (root, 0600) | stays; only the supervisor mounts it, job containers never see it |

By default `GH_RUNNER_MEMORY_SWAP` equals `GH_RUNNER_MEMORY`. That means the job container can't swap, so its RAM, including the tmpfs work dir, is never written to the VM's swapfile. The cost is that checkout plus build must fit in `GH_RUNNER_MEMORY`. Raising `GH_RUNNER_MEMORY_SWAP` gives more room, but job data can then reach `/var/swapfile` on disk.

Job containers don't get the Docker socket, so a job can't control the host's other containers. The catch is that workflows using `container:`, `services:` or Docker-based actions won't work here. Keep those on GitHub-hosted runners.

## One-time setup

1. **Create a GitHub App**: Settings → Developer settings → GitHub Apps → New GitHub App.
   - Any name and homepage URL. Under Webhook, untick **Active**.
   - Repository permissions: **Administration: Read and write** (Metadata: read is added automatically). Nothing else.
   - Where can this app be installed: **Only on this account**.
2. Create it, note the **App ID**, then **Generate a private key** (downloads a `.pem`).
3. **Install App** → Only select repositories → your private repo.
4. In this repo's Actions secrets:
   - `GH_RUNNER_REPO` = `https://github.com/OWNER/REPO` (the private repo)
   - `GH_RUNNER_APP_ID` = the App ID
   - `GH_RUNNER_APP_PRIVATE_KEY` = the whole `.pem` content
   - delete the old `GH_RUNNER_REG_TOKEN`, `GH_RUNNER_EPHEMERAL`, `GH_RUNNER_DISABLE_AUTO_UPDATE`, `GH_RUNNER_WORK_DIR`
5. Run **Run Bash Scripts on GCP VM** → `upsert-github-runner`. It checks the credentials before touching the running runner, removes the old myoung34 container, and starts the supervisor.
6. In the private repo: `runs-on: [self-hosted, gcp-free-tier]`.

**Quickest: no new secrets.** Without the App secrets, the deploy uses the existing `PRIVATE_REPO` (as the repo) and `PRIVATE_REPO_TOKEN` (as a PAT) when `GH_RUNNER_REPO`/`GH_RUNNER_PAT` are not set. The token then also needs **Administration: Read and write** on that repo (a classic PAT: the `repo` scope); the deploy checks this before changing anything. It is stored on the host (root only, never visible to jobs), and when it expires the runner stops until you renew it, which you would do anyway for the other workflows that use it.

A dedicated fine-grained PAT with **Administration: Read and write** on the repo works too (`GH_RUNNER_PAT`). Any PAT has an expiry date, though, so the App is the one that never needs touching again.

## Settings (Actions secrets, all optional)

| Secret | Default | Meaning |
|---|---|---|
| `GH_RUNNER_NAME` | VM name | Runner name prefix (`<prefix>-<time>-<rand>`). Must be unique per host: offline runners with this prefix are deleted. |
| `GH_RUNNER_LABELS` | `self-hosted,linux,x64,gcp-free-tier` | Labels for `runs-on` |
| `GH_RUNNER_CPUS` | `0.50` | CPU cap per job |
| `GH_RUNNER_MEMORY` | `512m` | RAM cap per job, tmpfs included |
| `GH_RUNNER_MEMORY_SWAP` | = memory | RAM+swap cap; equal to memory = no swap (see above) |
| `GH_RUNNER_WORK_SIZE` | `1g` | Max size of the tmpfs work dir (actual use counts against memory) |
| `GH_RUNNER_TMP_SIZE` | `256m` | Max size of the tmpfs `/tmp` |
| `GH_RUNNER_NO_SUDO` | `0` | `1` = drop all capabilities and set `no-new-privileges`: no `sudo`/`apt` in jobs, but much less a job can do |
| `GH_RUNNER_CONTAINER_NAME` | `github-runner` | Name of the old myoung34 container to remove |

`GH_RUNNER_NETWORK` (default `host`, needed for NAT64 on the IPv6-only VM), `GH_RUNNER_IMAGE` (default `ghcr.io/actions/actions-runner:latest`, re-pulled every 6 h) and `GH_RUNNER_DNS` are also read when set in the environment.

## On Instabox

[`instabox-github-runner.yaml`](../../.github/workflows/instabox-github-runner.yaml) deploys only this supervisor, on its own [Instabox](https://instabox.sh) machine (`gh-runner`, template `agent-browser`, 4 vCPU / 8 GB), with the existing `INSTABOX_API_KEY`, `PRIVATE_REPO` and `PRIVATE_REPO_TOKEN` secrets. Each job gets 3 CPUs, 6 GB and a 4 GB RAM work dir by default, and its own Docker network, so it can't reach anything bound to the host's localhost. Deploy it once. After that, whenever the machine is online again (resumed, started with the workflow's `wake` mode or the dashboard, or booted fresh), the runner reconnects to the private repo with nothing to do on your side:

- **Resumed from a pause** (memory kept): the idle runner reconnects by itself. If GitHub still shows it offline 3 minutes later, or has deleted it (GitHub removes unused ephemeral runners after a day offline), the supervisor replaces it with a newly registered one.
- **Booted fresh:** Docker, enabled at boot by the deploy, restarts the supervisor. It deletes the old offline runner and registers a new one.
- **Jobs queued while the machine is off** wait in GitHub's queue (up to 24 hours) and run once it's back. A job that was running when the machine went off fails, and its container is replaced.

Nothing from the runner is kept on that machine's disk: the deploy turns swap off and keeps the system journal in RAM (`GH_RUNNER_HOST_RAM_ONLY=1`), the supervisor logs to its own RAM `/tmp`, and job containers keep no log.

Use `runs-on: [self-hosted, instabox]`.

## Operating

```bash
docker exec gh-runner-supervisor tail -f /tmp/supervisor.log   # [+] runner ... online, waiting for a job (log in RAM)
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v /var/lib/gh-runner:/run/secrets/gh-runner:ro -e GH_RUNNER_REPO=OWNER/REPO \
  -e GH_RUNNER_APP_ID=123 sudtanj/github-runner check   # credentials + permission check
docker stop gh-runner-supervisor           # pause (stays stopped across reboots until started)
```

One job at a time, sized for the 1 GB e2-micro. Heavy builds (Android, Docker images) belong on GitHub-hosted runners.

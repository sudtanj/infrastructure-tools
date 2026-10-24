# Infrastructure Tools

A public repository sharing my personal infrastructure automation collection that I actively use to provision, manage, and deploy personal services.

## Overview & Architecture

This repository contains IaC (Terraform), orchestration scripts, and GitHub Actions workflows for managing personal services across Google Cloud Platform and Oracle Cloud Infrastructure:

- **GCP IPv6-only external networking**: Avoids external IPv4 charges while preserving access through secure internal services.
- **Identity-Aware Proxy (IAP) SSH**: Secure VM management without exposing SSH publicly.
- **Tailscale mesh**: Secure overlay networking across services.
- **Container-Optimized OS (COS)**: Persistent kernel-mode Tailscale and Portainer managed through `cloud-init`.
- **OCI Always Free capacity acquisition**: A scheduled, idempotent workflow that attempts to provision an Oracle Cloud A1.Flex instance when capacity is available.

---

## Repository Structure

```
.
├── .github/workflows/
│   ├── botkeep-deploy.yaml          # Auto-deploy every botkeep* root folder to its Botkeep workload
│   ├── gcp-bash-script-runner.yaml   # Remote script execution via GCP IAP SSH
│   ├── instabox-paseo-lite.yaml      # Deploy paseo-lite (Claude Code + Codex) on an Instabox machine
│   ├── terraform-deploy.yml          # Format, plan, and protected apply for all HCP Terraform directories
│   ├── terraform-free-tier-oci.yaml  # Scheduled OCI A1.Flex capacity-grab workflow
│   ├── workflow-cleanup-job.yaml     # Daily cleanup of GitHub Actions runs
│   ├── job-hunter.yaml               # Manual: find remote jobs matching your CV, report to the private repo
│   ├── job-apply.yaml                # Manual: fill in and submit one job application in the saved Chrome (profile + Codex endpoint)
│   ├── ats-cv.yaml                   # Manual: ATS-friendly PDF CV from the job hunter's cv.md, into the private repo
│   ├── tanoitcorp-blog.yaml          # Every 2 days: new AI-written tech posts on the Tanoit Corp site, into the private repo
│   ├── search-engine-register.yaml   # Weekly: register every Cloudflare Workers/Pages website with Google Search Console and Bing (Yahoo)
│   ├── tokopedia-search.yaml         # Manual: 10 cheapest Tokopedia listings from well-rated sellers, into the private repo
│   ├── shopee-search.yaml            # Manual: 10 cheapest Shopee listings from Star/Mall sellers, into the private repo
│   ├── commute-traffic.yaml          # Weekdays 08:00/11:00 home to work, 17:00/18:00 work to home: Google Maps traffic (first run also predicts the second), Waze reports, odd-even, CCTV, weather, to Telegram
│   ├── apps-private-build.yaml       # Build a private repo's apps/ for Android, iOS, Windows, macOS, Linux; publish as its release
│   └── builder-tools-*.yml           # Docker image publish, PR check, dependabot merge, Mi 3 firmware and Orange Pi image builds for builder-tools/
├── builder-tools/                    # Docker images (Docker Hub) + Padavan firmware and Orange Pi Zero 3 Armbian image builders, migrated from sudtanj/builder-tools
├── bash-scripts/
│   ├── deploy-botkeep.sh             # Upload a folder to Botkeep via the Developer API
│   ├── init-paseo-codex.sh           # Deploy & maintain Codex CLI agent container
│   ├── init-paseo-lite.sh            # Deploy & maintain paseo-lite (Rust Paseo + native Claude Code/Codex)
│   ├── upsert-github-runner.sh    # Upsert GitHub Actions self-hosted runner
│   ├── init-n8n.sh                   # Deploy n8n workflow automation, tuned for free tier
│   ├── init-tailscale.sh             # Install, update & configure Tailscale (idempotent)
│   ├── test-codex-url.sh             # Read-only: test CODEX_BASE_URL from the VM step by step (DNS, route, TCP, /models, /responses)
│   ├── reset-containers.sh           # Stop & remove all running containers, keep volumes
│   ├── init-dozzle.sh                # Light container logs/stats/actions web UI on port 27461
│   ├── init-kongming.sh              # Deploy & maintain kongming (Rust agentic AI daemon, state on Turso, read-only image)
│   └── init-portainer.sh             # Deploy latest Portainer only
├── terraform_free_tier_gcp/
│   ├── cloud-init.yaml.tftpl         # Cloud-config for COS startup, Tailscale & Portainer setup
│   ├── main.tf                       # GCP e2-micro instance, firewall, and SA definitions
│   ├── variables.tf                  # Variable schemas
│   └── terraform.tfvars.example      # Sample configuration file
└── terraform_free_tier_oci/
    ├── main.tf                       # OCI A1.Flex instance and related outputs
    └── variables.tf                  # OCI provider and instance variables
```

---

## Key Components

### 1. Terraform GCP Free Tier (`terraform_free_tier_gcp/`)

Provisions a zero-cost `e2-micro` Google Compute Engine instance in supported regions (`us-west1-a` default) with:

- 30 GB standard persistent disk (`pd-standard`).
- Container-Optimized OS (`cos-cloud/cos-stable`).
- Dual-stack IPv4/IPv6 internal networking with **IPv6-only public egress/ingress**.
- GCP IAP firewall rules allowing secure SSH tunneling.
- Automated VM replacement when `cloud-init.yaml.tftpl` changes (`terraform_data.cloud_init_trigger`).

### 2. Terraform Oracle Cloud Free Tier (`terraform_free_tier_oci/`)

Provisions an Oracle Cloud Always Free `VM.Standard.A1.Flex` instance in `ap-singapore-1` with:

- 2 OCPUs, 12 GB memory, and a 50 GB boot volume by default.
- The latest Oracle Linux 8 ARM image, while pinning an existing instance against image and SSH metadata drift.
- The first public subnet in the first VCN and an assigned public IP.
- Optional SSH public key configuration and sensitive outputs for network and instance details.
- `prevent_destroy = true` to avoid replacing an occupied free-tier instance.

The configuration uses HCP Terraform remote state and requires an existing VCN with at least one public subnet.

### 3. Startup & Management Scripts (`bash-scripts/`)

- **`init-paseo-codex.sh`**: Idempotent deployment script for running a custom Codex agent on host networking. Automatically syncs environment secrets (API keys, GitHub tokens) and handles rolling updates. Pulls the latest image from the registry on every run before touching the running container, enforces hard cgroup caps (default 0.40 CPU, 320 MiB RAM, 448 MiB RAM+swap, 192 PIDs, capped logs/tmpfs, Node heap 192 MiB, Claude Code telemetry/autoupdate off; override via `CPU_LIMIT`, `MEM_LIMIT`, etc.), and forwards Claude Code auth (`ANTHROPIC_*` / `CLAUDE_CODE_OAUTH_TOKEN`) straight through to the sessions Paseo launches.
- **`init-paseo-lite.sh`**: Same deployment pattern and the same secrets as `init-paseo-codex.sh` (`CODEX_*`, `GH_TOKEN`, `ANTHROPIC_*`, `CLAUDE_CODE_*`), for [`sudtanj/paseo-lite`](https://github.com/sudtanj/builder-tools/tree/main/paseo-lite): the Rust Paseo daemon with native Claude Code and Codex CLIs, no Node.js. One shared Codex app-server serves every project, and Claude processes are started per prompt and released when idle (at most `PASEO_CLAUDE_MAX_LIVE`, default 1). Uses its own container (`paseo-lite`), its own home volume (`paseo-lite-home`) and is pinned to port `6768`, since 6767 is already used by `init-paseo-codex.sh`. It refuses to start if something else holds 6768. Running both on one `e2-micro` exceeds its RAM, though, so deploy one of them. After the container starts it curls `CODEX_BASE_URL/models` from the host (same network as Codex) and reports whether the endpoint answers, rejects the key, or is unreachable and why (name not resolving, connection refused, timeout, not routed via `tailscale0`); it only warns, the deploy still succeeds. The relay pairing link is never logged; run `docker exec paseo-lite paseo-lite pair` on the VM to show it.
- **`upsert-github-runner.sh`**: Idempotent upsert of a GHCR GitHub Actions runner, capped at 0.50 CPU and 256 MiB memory.
- **`init-n8n.sh`**: Idempotent n8n deployment sized for the free-tier `e2-micro`. Uses SQLite instead of Postgres/Redis, caps the container at 0.50 CPU / 512 MiB with a matching V8 heap limit, disables telemetry/version/template calls to preserve the free egress allowance, publishes the UI on loopback plus the Tailscale address only, and installs a daily local backup of the data volume. The credential `N8N_ENCRYPTION_KEY` is generated once and persisted in `/etc/n8n/n8n.env` (mode 600) so re-runs never orphan stored credentials.
- **`init-tailscale.sh`**: Idempotent Tailscale install, update and configuration. Installs or updates the binaries to the latest stable (reusing the cloud-init install in `/var/lib/docker/tailscale-bin`), writes the resource-capped `tailscaled` systemd unit, authenticates with `TS_AUTHKEY` when needed, verifies the node is healthy, and rolls back to the previous binaries if an update fails. By default it also registers the VM as a tailnet exit node: it turns on IP forwarding (`/etc/sysctl.d/99-tailscale.conf`, keeping IPv6 router advertisements working) and advertises the exit route, also on nodes that are already logged in. Approve it by hand in the admin console (Machines → Edit route settings → Use as exit node); the script only advertises it. Set `TS_EXIT_NODE=0` to stop advertising it. Traffic through the exit node counts against the VM's free-tier egress. It also accepts the subnet routes other nodes advertise (for example a home LAN behind the Orange Pi's `OPI_TS_ROUTES`), so the VM reaches those addresses too; if an accepted route would capture the VPC gateway or the metadata server, it turns that back off and warns. Set `TS_ACCEPT_ROUTES=0` to ignore them. It then checks that peers answer through `tailscale0` (real ICMP, or a TCP connection for `host:port`), so a tailnet ACL or peer firewall that drops the traffic shows up; a failure says whether the address is not routed into the tailnet, has no WireGuard path, or is dropped by the ACL/firewall. Put the peers that must answer in the `TAILSCALE_PING_PEER` secret (comma separated: an IP or name is pinged, `host:port` gets a TCP connection, and an `http(s)://` URL such as `http://192.168.1.10:20129/v1/models` must get an HTTP response from curl), which fails the run when one does not. `CODEX_BASE_URL` (forwarded with the other `CODEX_` secrets) is checked the same way, as `<CODEX_BASE_URL>/models`, logging only its host and port, so a run shows whether Codex in paseo-lite can reach its endpoint over the tailnet. With neither set, up to 3 online peers are pinged and a failure only warns.
- **`test-codex-url.sh`**: Read-only check of `CODEX_BASE_URL` from the VM (pick `test-codex-url` in the GCP runner), to find where a failing Codex in paseo-lite breaks. It goes step by step: name resolution (MagicDNS names fail behind DNS64), the route (via `tailscale0`, or a subnet route that is not accepted), `tailscale ping` for a 100.x peer, a TCP connection (tailnet ACL, peer firewall, or a service bound to `127.0.0.1`), `GET /models` with `CODEX_API_KEY` (and whether `CODEX_MODEL` is listed), a tiny `POST /responses` with `CODEX_MODEL` (the call Codex makes, so a router without the Responses API shows up), and the same `/models` call from inside the running `paseo-lite` container. The key goes to curl on stdin and only the host and port are logged. It fails when the endpoint does not answer the Responses call (or `/models` without `CODEX_MODEL`), and is skipped when `CODEX_BASE_URL` is unset.
- **`reset-containers.sh`**: Stops and removes every running Docker container without touching volumes, so re-running the `init-*.sh` scripts restores the services with their data. Excluded from the workflow's `all` option; select `reset-containers` to run it.
- **`init-portainer.sh`**: Deploy or update latest Portainer CE container.
- **`init-dozzle.sh`**: Deploys [Dozzle](https://dozzle.dev), a lighter alternative to Portainer (about 10–20 MB of RAM) for live container logs, stats and start/stop/restart. Runs on both the GCP e2-micro (amd64) and an Orange Pi Zero 3 (arm64). Listens on all interfaces on port 27461 (set `DOZZLE_BIND` / `DOZZLE_PORT` to change), requires a login from the `DOZZLE_PASSWORD` secret (12+ characters, never logged), and keeps the in-browser shell off unless `DOZZLE_SHELL=1`. Capped at 0.25 CPU / 48 MiB (each cap only where the kernel's cgroups support it, so it runs on any Linux with Docker), logs at warn level, and keeps container logs smaller when the root filesystem is on an SD card. Set `DOZZLE_REPLACE_PORTAINER=1` to remove the Portainer container (its volume is kept).
- **`opi-init-tailscale-docker.sh`**: Runs Tailscale as the read-only distroless `sudtanj/tailscale` container (see `builder-tools/tailscale/`) for the Orange Pi Zero 3 or any Linux with Docker. Uses host networking and kernel mode, so the host and every other container use the tailnet exactly as with a host install. The host `tailscale` CLI keeps working through the shared `/run/tailscale` socket. Advertises an exit node by default (`OPI_TS_EXIT_NODE=0` to turn off) plus the subnets in `OPI_TS_ROUTES`, and turns on IP forwarding. Its only credential is the `TAILSCALE_OAUTH_CLIENT_SECRET` OAuth client the other workflows already use: a new node logs in with a one-off pre-approved auth key minted from it and tagged with `OPI_TS_TAGS` (kept in sync on later runs through the API), and the Orange Pi workflow passes the client only to this script. With the client also holding the `devices:core` + `devices:routes` scopes, it approves those routes and moves the node to the tailnet IP in `OPI_TS_IP`. The IP change is the last step, because it drops connections to the old IP. If a host `tailscaled` is running, it takes it over (same node identity) in a separate systemd unit, so a run over SSH through that tailnet still finishes, and it restores the host service if the container fails. Extra secrets: `OPI_TS_TAGS`, `OPI_TS_IP`, `OPI_TS_ROUTES`, `OPI_TS_HOSTNAME`. The Orange Pi workflow runs it only when picked by name, never under `all`.

### 4. GitHub Actions CI/CD (`.github/workflows/`)

- **`terraform-deploy.yml`**: Detects directories containing a Terraform `cloud {}` block, then runs formatting checks, initialization, plans, and protected applies for each detected workspace on pushes to `main` or manual dispatches.
- **`terraform-free-tier-oci.yaml`**: Attempts one OCI instance `terraform apply` every 15 minutes, or manually on demand. It skips an instance already present in state and treats known capacity or throttling errors as a retryable miss.
- **`gcp-bash-script-runner.yaml`**: Triggers remote execution of scripts (for example, `init-paseo-codex.sh` and `init-tailscale.sh`) directly on the target VM via `gcloud compute ssh` over IAP.
- **`instabox-paseo-lite.yaml`**: Manually dispatched; runs `init-paseo-lite.sh` on an [Instabox](https://instabox.sh/docs) machine (4 vCPU / 8 GB, 5 free) with the same secrets as the GCP runner, so Claude Code and Codex are set up the same way. Needs the `INSTABOX_API_KEY` secret. It creates the machine (repo variable `INSTABOX_MACHINE_NAME`, default `paseo-lite`, template `universal`) when missing, starts it when paused or stopped, and runs the script over SSH with a short-lived Instabox certificate, since `instabox exec` stops after 10 minutes. Instabox pauses a machine after 30 idle minutes unless your account has manual lifecycle, and the Paseo relay can't wake it. The default `mode: on-demand` publishes the daemon as an Instabox public URL (port 6768 is reserved by Instabox, so a small socat container forwards port 16768, or the `INSTABOX_PUBLIC_PORT` repo variable, to it), which needs the `PASEO_PASSWORD` secret since anyone can reach it. Opening that URL resumes the paused machine with the daemon still running: point a Paseo direct connection at it, or open it in a browser before using the relay. The URL is never logged; see it with `instabox port ls paseo-lite`. `mode: always-on` unpublishes the port and turns the idle pause off, which only works with manual lifecycle. Without it, uncomment the workflow's schedule for a best-effort keep-alive every 20 minutes. Show the pairing link with `instabox ssh paseo-lite -- docker exec paseo-lite paseo-lite pair`.
- **`local-llm-run.yaml`**: Manually dispatched; runs a small open model (default Qwen3 4B, also Qwen3 1.7B/8B, Gemma 3 4B, Llama 3.2 3B, Phi-4 mini) with Ollama on the free CPU runner and writes the answer to the run summary. Weights are cached per model in the Actions cache. The repo is public, so prompts and answers are public too.
- **`job-hunter.yaml`**: Manually dispatched; checks out the private repo and runs its `job-hunter/job_hunter.ts`, which reads your CV from `job-hunt/cv.md` in the private repo, collects remote software jobs from a throwaway SearXNG on the runner (Google, Bing, DuckDuckGo and others, searching Greenhouse, Lever, Ashby and Workable) plus the Remotive, Remote OK, Jobicy, We Work Remotely and Working Nomads feeds, scores the new ones against the CV with the 9router model on the tailnet, drafts copy-paste application answers for the top 5, and commits the report to `job-hunt/<timestamp>.md` in the private repo. Secrets are listed in the workflow header; the log shows counts only.
- **`ats-cv.yaml`**: Manually dispatched; runs the private repo's `job-hunter/ats_cv.ts`, which has the 9router model sort `job-hunt/cv.md` (saved from LinkedIn by `job-hunter.yaml` with `refresh_cv`) into a CV's sections, lays it out for applicant tracking systems (one column, standard headings, real text) and commits it as `job-hunt/<first name>_cv.pdf` in the private repo, printed to A4 by the runner's Chrome. The log shows counts only.
- **`tanoitcorp-blog.yaml`**: Runs every two days (and on demand); joins the tailnet like `ats-cv.yaml` and runs the private repo's `cloudflare-projects/tanoitcorp/blog/generate.ts`, which reads popular tech news feeds (TechCrunch, The Verge, Ars Technica, Engadget, Wired), has the `CODEX_*` endpoint (zilong-router) pick the most significant fresh stories and write an original article on each, keeping the source's cover image with a credit, and renders the static blog, RSS feed, sitemap and homepage cards. It commits and pushes them to the private repo, then deploys the site to Cloudflare Pages itself (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`). `PRIVATE_REPO_TOKEN` needs Contents: read and write. The log shows counts only.
- **`search-engine-register.yaml`**: Weekly (and on demand, with `dry_run`); runs `.github/scripts/search-engine-register.ts`, which lists the custom hostnames of every Cloudflare Pages project, Workers custom domain and Workers route, keeps the ones whose home page is indexable HTML, and registers them with no new secrets: in the saved chrome-cdp-session Chrome (or the running session with `session_browser`) it adds each zone as a Google Search Console domain property, puts the verification TXT record in place through `CLOUDFLARE_API_TOKEN`, verifies it and submits the sitemaps; it reads the Bing Webmaster API key from Bing's settings page and adds, verifies (DNS-only CNAME) and submits each site over the API. Yahoo serves Bing's index, so Bing covers it. Sign in to Google and Bing Webmaster Tools once over VNC, and give the existing Cloudflare token Zone Read, DNS Edit and Workers Routes Read. The log shows site-1, zone-1 labels, not hostnames.
- **`job-apply.yaml`**: Manually dispatched with a `job_url` (public: this repo is public) and an optional `dry_run`; restores the saved chrome-cdp-session Chrome, browses through the exit node, and runs the private repo's `job-hunter/job_apply.ts` (Playwright over CDP, installed on the run). It finds the form (Greenhouse, Ashby, Lever, or one embedded in a careers page), attaches the CV PDF, reads every question with its options, answers the standard ones from `job-hunt/profile.json` and has the `CODEX_*` endpoint (zilong-router; a small free model is enough) answer the rest from the profile's facts and `job-hunt/cv.md` as option numbers or short texts, which the script checks against the options before filling each widget itself and reading it back. A required question with no answer, a captcha or an emailed verification code stops it, and after the submit it fails unless the page confirms the application. The log shows the form's questions and counts, never an answer or the URL.
- **`tokopedia-search.yaml`**: Manually dispatched with a search `query`; restores the saved chrome-cdp-session Chrome profile (logged in to Tokopedia), browses through the exit node, and runs the private repo's `tokopedia_data/tokopedia.ts` (Playwright over CDP), which keeps the 10 cheapest new, non-sponsored listings from shops rated 4.9+ with a product rating of 4.8+ (10+ ratings) and commits them as `tokopedia_data/<query>.md` in the private repo. The log shows counts only.
- **`shopee-search.yaml`**: Same as `tokopedia-search.yaml` for Shopee: runs the private repo's `shopee_data/shopee.ts` (patchright over CDP, paced like a person: typed query, scrolling, sort and paging clicks) and commits the 10 cheapest non-sponsored listings from Star, Star+ or Mall sellers with a product rating of 4.8+ (10+ ratings) as `shopee_data/<query>.md`. A Shopee captcha fails the run; solve it over VNC in chrome-cdp-session. The log shows counts only.
- **`chrome-cdp-session.yaml`**: Manually dispatched; runs the latest stable Google Chrome on the runner, reachable only on the tailnet as `chrome-cdp` with CDP on port 9222 (for Playwright, Puppeteer or AI agents; connect by the 100.x IP) and VNC on 5900. The profile (logins, cookies, tabs) and the Tailscale identity are encrypted with `STATE_KEY` and stored on the private repo's `chrome-cdp-state` release, so the next run restores the same browser at the same tailnet IP. Runs until the browser is closed or nothing is connected over VNC or CDP for `idle_minutes` (default 30); past the 6-hour job limit it saves and continues in a new run. To look less like a bot it keeps `navigator.webdriver` false and sends traffic through the existing `TAILSCALE_EXIT_NODE` secret (turn off with `use_exit_node`), with `timezone` and `locale` inputs to match.
- **`commute-traffic.yaml`**: Runs Monday to Friday at 08:00, 11:00, 17:00 and 18:00 UTC+7 (crons `0 1`, `0 4`, `0 10` and `0 11 * * 1-5`; skips public holidays when the `HOLIDAY_COUNTRY` secret is set) and on demand. Restores the saved chrome-cdp-session Chrome profile (read-only), browses through the `TAILSCALE_EXIT_NODE` exit node like `tokopedia-search.yaml`, and runs the private repo's `commute_traffic/commute_traffic.ts` (Playwright over CDP), which reads the Google Maps driving time in live traffic from `HOME_ADDRESS` to `WORK_ADDRESS` in the morning and back in the afternoon (manual runs: the `direction` input, or by time of day), plus, on the 08:00 and 17:00 runs, Google's typical range for leaving at 11:00 or 18:00, arrival times, the accidents, hazards, road closures and heavy jams Waze Live Map reports on the route, Jakarta's odd-even plate rule on the route's streets (optional `PLATE_PARITY` secret: odd or even), live snapshots from DKI's public CCTV on the route, and rain and air quality from Open-Meteo, and queues the summary, a map of route 1 coloured by its own Waze jams (listed in the summary in driving order), a Google Maps screenshot of the routes and the CCTV photos; after the runner leaves the tailnet (Telegram times out through the exit node) they are sent to Telegram (`TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`). Addresses live only in secrets; the log shows the step reached, route, report and camera counts and, on failure, the kind of page Google showed.
- **`workflow-cleanup-job.yaml`**: Automated daily run maintenance keeping workflow execution logs clean.

---

## Getting Started

### Prerequisites

- GCP account with an active project
- Oracle Cloud account with an Always Free-eligible tenancy and compartment
- HCP Terraform organization and workspaces
- [Terraform CLI](https://developer.hashicorp.com/terraform/downloads) >= 1.6.0
- Tailscale auth key
- Bcrypt-hashed password for Portainer admin access

### Running a bash script on the VM

Dispatch **Run Bash Scripts on GCP VM** (`.github/workflows/gcp-bash-script-runner.yaml`) and pick a script, or `all`. The script is streamed to the VM over `gcloud compute ssh --tunnel-through-iap` and executed there with `bash -s`. Scripts that need root use `sudo` when they are not already running as root.

Settings are read from repository secrets whose names begin with one of the prefixes in the workflow's `SECRET_FILTER`. n8n settings use the `N8N_` prefix:

| Secret | Purpose |
| --- | --- |
| `N8N_ENCRYPTION_KEY` | Optional. Pins the credential encryption key instead of letting the script generate and persist one. A value that differs from the key already in `/etc/n8n/n8n.env` is rejected, because changing it would make stored credentials unreadable. |
| `N8N_MEMORY_LIMIT` | Container memory cap (default `512m`). The `e2-micro` has 1 GB shared with Portainer and the Actions runner, so the script warns when the cap plus its reserved budget exceeds host RAM. |
| `N8N_PUBLIC_URL` | Public URL for editor links and webhook callbacks. Derived from the Tailscale address when unset. |
| `N8N_BACKUP_ENABLED` | Set to `false` to skip installing the daily backup timer. |

On the first run, open the UI and create the owner account. The setup URL embeds a bearer token, so the script never logs it; read it yourself with `docker logs n8n 2>&1 | grep -m1 '/rest/owner/setup/'`.

Claude Code auth for the Paseo containers (`init-paseo-codex.sh`, `init-paseo-lite.sh`) uses the `ANTHROPIC_` and `CLAUDE_CODE_` prefixes. All are optional — with none set, run `claude /login` once inside the container (credentials persist in the `paseo-home` volume):

| Secret | Purpose |
| --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Subscription auth (Pro/Max). Generated with `claude setup-token` on your own machine; charges your subscription, not usage. |
| `ANTHROPIC_API_KEY` | API-key billing instead of subscription (`sk-ant-...`). Leave unset if using the subscription. |
| `ANTHROPIC_BASE_URL` | BYOK: your Anthropic-API-compatible gateway, instead of `api.anthropic.com`. |
| `ANTHROPIC_AUTH_TOKEN` | BYOK: bearer token sent as `Authorization: Bearer` instead of `x-api-key`. |
| `ANTHROPIC_MODEL` | Optional default model (for example `claude-sonnet-5-5`). Unset uses Claude Code's built-in default. |

Only secrets that are actually set get forwarded — an absent secret never lands in the container as an empty string. Every run of the script also pulls the latest `sudtanj/paseo-codex` image before touching the running container, so a failed pull leaves the current deployment up.

`PASEO_PASSWORD` (optional, recommended) is the password for direct connections to the Paseo daemons: `init-paseo-codex.sh` on `:6767` and `init-paseo-lite.sh` on `:6768`. Set it as a repository secret and rerun the script; a new or changed value recreates the container. Without it, anyone who can reach the port (for example over the tailnet) connects unauthenticated, and paseo-lite's built-in pairing page stays disabled. Relay clients still pair with the QR link, as before. In the Paseo app, add a direct connection to `<vm-tailscale-ip>:6768` and enter the same password.

`PASEO_APP_BASE_URL` (optional, a repository variable or secret) changes where `init-paseo-lite.sh`'s pairing QR/link opens the app, for example `https://sudtanj.github.io/paseo-lite` for the GitHub Pages build of the Paseo web app in `sudtanj/paseo-lite`. Unset keeps `https://app.paseo.sh`. Setting or changing it recreates the container on the next run.

### GCP Local Deployment

1. Clone the repository:
   ```bash
   git clone https://github.com/sudtanj/infrastructure-tools.git
   cd infrastructure-tools/terraform_free_tier_gcp
   ```

2. Create your variable file:
   ```bash
   cp terraform.tfvars.example terraform.tfvars
   ```

3. Fill in required variables in `terraform.tfvars`:
   ```hcl
   gcp_project_id                = "your-gcp-project-id"
   zone                          = "us-west1-a"
   tailscale_auth_key            = "tskey-auth-xxxx"
   portainer_admin_password_hash = "$2a$12$..."
   ```

4. Initialize and apply:
   ```bash
   terraform init
   terraform apply
   ```

5. Connect via IAP SSH:
   ```bash
   gcloud compute ssh <vm_name> --zone us-west1-a --tunnel-through-iap
   ```

### Oracle Cloud Deployment

Configure an HCP Terraform workspace named `<prefix>-terraform_free_tier_oci`, then provide:

| Type | Name | Purpose |
| --- | --- | --- |
| GitHub Actions secret | `TF_API_TOKEN` | HCP Terraform API token |
| GitHub Actions secret | `TF_CLOUD_ORGANIZATION` | HCP Terraform organization |
| GitHub Actions secret | `TF_WORKSPACE_PREFIX` | Optional workspace prefix; defaults to `tf` |
| Terraform variable | `tenancy_ocid` | OCI tenancy OCID |
| Terraform variable | `user_ocid` | OCI API user OCID |
| Terraform variable | `api_key_fingerprint` | OCI API key fingerprint |
| Terraform variable | `api_key_private_key` | OCI API private key |
| Terraform variable | `compartment_ocid` | OCI compartment OCID |
| Terraform variable | `ssh_public_key` | Optional public SSH key |

Run **OCI Free Tier - Capacity Grab** manually to attempt provisioning once, or leave its schedule enabled for best-effort attempts every 15 minutes. Existing instances are skipped, and known OCI capacity or throttling errors are reported as a missed window for retry on the next run.

---

## License

Personal collection — shared publicly under the MIT License.

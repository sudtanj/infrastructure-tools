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
│   ├── gcp-bash-script-runner.yaml   # Remote script execution via GCP IAP SSH
│   ├── terraform-deploy.yml          # Format, plan, and protected apply for all HCP Terraform directories
│   ├── terraform-free-tier-oci.yaml  # Scheduled OCI A1.Flex capacity-grab workflow
│   └── workflow-cleanup-job.yaml     # Daily cleanup of GitHub Actions runs
├── bash-scripts/
│   ├── init-paseo-codex.sh           # Deploy & maintain Codex CLI agent container
│   ├── upsert-github-runner.sh    # Upsert GitHub Actions self-hosted runner
│   ├── init-n8n.sh                   # Deploy n8n workflow automation, tuned for free tier
│   ├── init-tailscale.sh             # Dedicated Tailscale deployment & configuration script
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
- **`upsert-github-runner.sh`**: Idempotent upsert of a GHCR GitHub Actions runner, capped at 0.50 CPU and 256 MiB memory.
- **`init-n8n.sh`**: Idempotent n8n deployment sized for the free-tier `e2-micro`. Uses SQLite instead of Postgres/Redis, caps the container at 0.50 CPU / 512 MiB with a matching V8 heap limit, disables telemetry/version/template calls to preserve the free egress allowance, publishes the UI on loopback plus the Tailscale address only, and installs a daily local backup of the data volume. The credential `N8N_ENCRYPTION_KEY` is generated once and persisted in `/etc/n8n/n8n.env` (mode 600) so re-runs never orphan stored credentials.
- **`init-tailscale.sh`**: Tailscale installation and lifecycle management script.
- **`update-tailscale.sh`**: Updates the Tailscale binaries installed by `cloud-init.yaml.tftpl` (`/var/lib/docker/tailscale-bin`) to the latest stable (or `TS_VERSION`), restarting `tailscaled` and rolling back if it fails to start. Keeps the node auth and systemd unit untouched.
- **`init-portainer.sh`**: Deploy or update latest Portainer CE container.

### 4. GitHub Actions CI/CD (`.github/workflows/`)

- **`terraform-deploy.yml`**: Detects directories containing a Terraform `cloud {}` block, then runs formatting checks, initialization, plans, and protected applies for each detected workspace on pushes to `main` or manual dispatches.
- **`terraform-free-tier-oci.yaml`**: Attempts one OCI instance `terraform apply` every 15 minutes, or manually on demand. It skips an instance already present in state and treats known capacity or throttling errors as a retryable miss.
- **`gcp-bash-script-runner.yaml`**: Triggers remote execution of scripts (for example, `init-paseo-codex.sh` and `init-tailscale.sh`) directly on the target VM via `gcloud compute ssh` over IAP.
- **`workflow-cleanup-job.yaml`**: Automated daily run maintenance keeping workflow execution logs clean.
- **`botkeep-deploy.yml`**: Reusable workflow (`workflow_call`) that auto-deploys a repo to a [botkeep.cloud](https://botkeep.cloud) workload. See [Auto-deploy to Botkeep](#auto-deploy-to-botkeep).

#### Auto-deploy to Botkeep

Use the reusable workflow from any project to sync a branch into a Botkeep workload on every push.

1. In the Botkeep panel, create an API key with scopes `deploy:write`, `workloads:read` and `settings:read`, and note your workload ID and name.
2. In the target repo, add the API key as a secret named `BOTKEEP_API_KEY` (Settings → Secrets and variables → Actions).
3. Copy [`github-action-templates/botkeep-deploy-caller.yml`](github-action-templates/botkeep-deploy-caller.yml) to `.github/workflows/deploy.yml` in that repo and set `workload_id` and `confirmation` (the workload name).
4. Push to `main` (or run the workflow manually). The job reads the workload's current revision, triggers `POST /github/sync`, and polls the operation until it succeeds or fails.

Minimal caller:

```yaml
jobs:
  deploy:
    uses: sudtanj/infrastructure-tools/.github/workflows/botkeep-deploy.yml@main
    with:
      workload_id: "YOUR_WORKLOAD_ID"
      confirmation: "YOUR_WORKLOAD_NAME"
    secrets:
      BOTKEEP_API_KEY: ${{ secrets.BOTKEEP_API_KEY }}
```

| Input | Default | Description |
| --- | --- | --- |
| `workload_id` (required) | | Botkeep workload ID |
| `confirmation` (required) | | Confirmation string for the sync endpoint (workload name) |
| `repository` | calling repo | `owner/name` to sync |
| `branch` | triggering ref | Branch to deploy |
| `access` | `public` | `public`, or `connection` for private repos (needs a GitHub connection linked in Botkeep) |
| `mode` | `merge` | `merge`, `replace` or `folder` |
| `directory` | | Target directory (only for `mode: folder`) |
| `restart` | `true` | Restart the workload after sync |
| `base_url` | `https://botkeep.cloud` | API host |
| `timeout_seconds` | `600` | Max wait for the operation |

Notes: if the repo calling this workflow is private, the calling repo must be allowed to use workflows from this one (Settings → Actions → Access on `infrastructure-tools`). Pin `@main` to a tag or SHA for stability.

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

Claude Code auth for the Paseo container uses the `ANTHROPIC_` and `CLAUDE_CODE_` prefixes. All are optional — with none set, run `claude /login` once inside the container (credentials persist in the `paseo-home` volume):

| Secret | Purpose |
| --- | --- |
| `CLAUDE_CODE_OAUTH_TOKEN` | Subscription auth (Pro/Max). Generated with `claude setup-token` on your own machine; charges your subscription, not usage. |
| `ANTHROPIC_API_KEY` | API-key billing instead of subscription (`sk-ant-...`). Leave unset if using the subscription. |
| `ANTHROPIC_BASE_URL` | BYOK: your Anthropic-API-compatible gateway, instead of `api.anthropic.com`. |
| `ANTHROPIC_AUTH_TOKEN` | BYOK: bearer token sent as `Authorization: Bearer` instead of `x-api-key`. |
| `ANTHROPIC_MODEL` | Optional default model (for example `claude-sonnet-5-5`). Unset uses Claude Code's built-in default. |

Only secrets that are actually set get forwarded — an absent secret never lands in the container as an empty string. Every run of the script also pulls the latest `sudtanj/paseo-codex` image before touching the running container, so a failed pull leaves the current deployment up.

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

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

- **`init-paseo-codex.sh`**: Idempotent deployment script for running a custom Codex agent on host networking. Automatically syncs environment secrets (API keys, GitHub tokens) and handles rolling updates.
- **`upsert-github-runner.sh`**: Idempotent upsert of a GHCR GitHub Actions runner, capped at 0.50 CPU and 256 MiB memory.
- **`init-tailscale.sh`**: Tailscale installation and lifecycle management script.
- **`init-portainer.sh`**: Deploy or update latest Portainer CE container.

### 4. GitHub Actions CI/CD (`.github/workflows/`)

- **`terraform-deploy.yml`**: Detects directories containing a Terraform `cloud {}` block, then runs formatting checks, initialization, plans, and protected applies for each detected workspace on pushes to `main` or manual dispatches.
- **`terraform-free-tier-oci.yaml`**: Attempts one OCI instance `terraform apply` every 15 minutes, or manually on demand. It skips an instance already present in state and treats known capacity or throttling errors as a retryable miss.
- **`gcp-bash-script-runner.yaml`**: Triggers remote execution of scripts (for example, `init-paseo-codex.sh` and `init-tailscale.sh`) directly on the target VM via `gcloud compute ssh` over IAP.
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

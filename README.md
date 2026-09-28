# Infrastructure Tools

A public repository sharing my personal infrastructure automation collection that I actively use to provision, manage, and deploy personal services.

## Overview & Architecture

This repository contains IaC (Terraform), orchestration scripts, and GitHub Actions workflows designed around GCP's Always Free tier constraints:

- **Strictly IPv6-only External Networking**: Eliminates GCP's external IPv4 address charges ($0.005/hr).
- **Identity-Aware Proxy (IAP) SSH**: Secure management access over IPv4 without public IPv4 exposure.
- **Tailscale Mesh**: Secure overlay networking across services.
- **Container-Optimized OS (COS)**: Persistent kernel-mode Tailscale and Portainer via `cloud-init`.

---

## Repository Structure

```
.
├── .github/workflows/
│   ├── gcp-bash-script-runner.yaml   # Remote script execution via GCP IAP SSH
│   ├── terraform-deploy.yml          # Dynamic directory detection & HCP Terraform integration
│   └── workflow-cleanup-job.yaml     # Daily cleanup of GitHub Actions runs
├── bash-scripts/
│   ├── init-paseo-codex.sh           # Deploy & maintain Codex CLI agent container
│   └── init-tailscale-portainer.sh   # Standalone Tailscale & Portainer deployment script
└── terraform_free_tier_gcp/
    ├── cloud-init.yaml.tftpl         # Cloud-config for COS startup, Tailscale & Portainer setup
    ├── main.tf                       # GCP e2-micro instance, firewall, and SA definitions
    ├── variables.tf                  # Variable schemas
    └── terraform.tfvars.example      # Sample configuration file
```

---

## Key Components

### 1. Terraform GCP Free Tier (`terraform_free_tier_gcp/`)

Provisions a zero-cost `e2-micro` Google Compute Engine instance in US regions (`us-west1-a` default) with:
- 30 GB standard persistent disk (`pd-standard`).
- Container-Optimized OS (`cos-cloud/cos-stable`).
- Dual-stack IPv4/IPv6 internal networking with **IPv6-only public egress/ingress**.
- GCP IAP firewall rules allowing secure SSH tunneling.
- Automated VM replacement when `cloud-init.yaml.tftpl` changes (`terraform_data.cloud_init_trigger`).

### 2. Startup & Management Scripts (`bash-scripts/`)

- **`init-paseo-codex.sh`**: Idempotent deployment script for running a custom Codex agent on host networking. Automatically syncs environment secrets (API keys, GitHub tokens) and handles rolling updates.
- **`init-tailscale-portainer.sh`**: Helper script for manual host setup of Tailscale VPN and Portainer container management UI.

### 3. GitHub Actions CI/CD (`.github/workflows/`)

- **`terraform-deploy.yml`**: Automatically detects directories with `.tf` files and runs matrixed `fmt`, `plan`, and manual-approval `apply` using HCP Terraform remote backends and GCP Workload Identity Federation.
- **`gcp-bash-script-runner.yaml`**: Triggers remote execution of scripts (e.g., `init-paseo-codex.sh`) directly on the target VM via `gcloud compute ssh` over IAP.
- **`workflow-cleanup-job.yaml`**: Automated daily run maintenance keeping workflow execution logs clean.

---

## Getting Started

### Prerequisites
- GCP Account with an active project
- [Terraform CLI](https://developer.hashicorp.com/terraform/downloads) >= 1.5.0
- Tailscale Auth Key
- Bcrypt-hashed password for Portainer admin access

### Local Deployment

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/infrastructure-tools.git
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

---

## License

Personal collection — shared publicly under the MIT License.

# Oracle Cloud Free Tier (Singapore) - Terraform

Provision Always Free resources in Oracle Cloud Singapore (`ap-singapore-1`) using Terraform with separate GitHub Actions workflow.

**Key differences from GCP free tier:**
- Region: `ap-singapore-1` (Always Free eligible)
- Compute: ARM Ampere (`VM.Standard.A1.Flex`, 1 OCPU, 6 GB)
- Network: VCN + subnet (`10.0.0.0/16` / `10.0.0.0/24`)
- Security: Security list allows SSH (22), HTTP (80), HTTPS (443), and Tailscale UDP (41641)
- Image: Oracle Linux 8 (Open Source) pre-installed

## Requirements

- OCI account with Always Free eligible region (`ap-singapore-1`)
- API key added to your OCI user
- Compartment OCID (container where resources will be created)
- Public SSH key for Linux admin access

## Setup

### 1. Add OCI credentials to GitHub Secrets

Create the following secrets in your GitHub repository (Settings → Secrets and variables → Actions):

| Secret name | Description |
|-------------|-------------|
| `OCI_TENANCY_OCID` | Your tenancy OCID (root compartment) |
| `OCI_USER_OCID` | Your user OCID |
| `OCI_FINGERPRINT` | API key fingerprint |
| `OCI_PRIVATE_KEY` | Full PEM private key (multiline) |
| `OCI_COMPARTMENT_OCID` | OCID of your compartment |

### 2. (Optional) Adjust variables

Copy and adapt `variables.tf` as needed, or set defaults via `terraform.tfvars`.

### 3. Run via GitHub Actions

Use the **Terraform OCI** workflow:

- Choose `terraform-plan` to plan only (default)
- Choose `terraform-apply` and type `yes` for auto-apply

The workflow runs in the `oracle-cloud-free-tier` directory, isolating OCI resources from GCP.

## Always Free Considerations

- **Compute:** `VM.Standard.A1.Flex` offers 1 OCPU and 6 GB for free (monthly 744 hours)
- **Networking:** Standard tier (200 GB/month outbound egress free)
- **Database:** Free tier includes one autonomous database (including small ADW)
- **Load Balancing:** One registerable free tier load balancer
- **Object Storage:** Segments up to 10 TB for free

## Outputs

After successful apply:

- `instance_public_ip` — Public IP to access the VM
- `instance_private_ip` — Private IP for internal communication
- `vcn_id` — VCN OCID
- `subnet_id` — Subnet OCID

# Oracle Cloud Free Tier Claimer

Runs [sudtanj/infrastructure_scripts](https://github.com/sudtanj/infrastructure_scripts/tree/main/oracle-cloud-free-tier)
(Terraform that provisions/reconciles Oracle Cloud Always Free resources in
`ap-singapore-1`) on a schedule inside a slim multi-arch container
(`linux/amd64` and `linux/arm64`).

All OCI credentials are provided directly inside the `environment:` block of
`docker-compose.yml` or `docker-compose.hub.yml` — no separate `.env` file required.

## Quick start

1. Edit `docker-compose.yml` (or `docker-compose.hub.yml`) and fill in your OCI details in the `environment:` block:
   - `OCI_TENANCY_OCID`
   - `OCI_USER_OCID`
   - `OCI_FINGERPRINT`
   - `OCI_PRIVATE_KEY_BASE64` (or `OCI_PRIVATE_KEY`)
   - `OCI_COMPARTMENT_OCID`

2. Run with Docker Compose:

```bash
# Local build:
docker compose up -d

# Or pull pre-built image:
docker compose -f docker-compose.hub.yml up -d

# Build multi-arch manually (optional):
docker buildx build --platform linux/amd64,linux/arm64 -t sudtanj/oracle-cloud-free-tier-claimer .

# Single run then exit (CI-style):
docker compose run --entrypoint "sh -c 'RUN_ONCE=1 /usr/local/bin/entrypoint.sh'" oracle-cloud-free-tier-claimer

# Watch logs:
docker compose logs -f
```

## How it works

- `entrypoint.sh` writes `terraform.tfvars` (and a private key file) from
  the environment variables at start, runs `terraform init`, then loops `terraform apply -auto-approve`.
- `RUN_INTERVAL` (default `300` seconds / 5min) controls the loop interval.
- `RUN_ONCE=1` exits after a single apply (useful for CI).
- Free-tier capacity is often exhausted, so a failed apply retries on the next interval automatically.

## Persisted state

The compose file mounts a named volume (`oci-terraform-state`) on `/workspace`,
so `terraform.tfstate` and provider plugins survive container restarts.

## Optional remote state

Set `TF_BACKEND_TYPE` (e.g. `s3`) plus `TF_BACKEND_BUCKET` / `TF_BACKEND_KEY` /
`TF_BACKEND_REGION` in your compose environment block to write a `backend.tf` on startup.

## Build args

- `TERRAFORM_VERSION` (default `1.6.0`) - pins the terraform binary; matches the version used upstream.

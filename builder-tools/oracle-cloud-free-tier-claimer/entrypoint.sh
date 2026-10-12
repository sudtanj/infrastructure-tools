#!/bin/sh
set -eu
WORKDIR="${WORKDIR:-/workspace}"
mkdir -p "$WORKDIR/.terraform.d/plugin-cache"
if [ "$(id -u)" = "0" ]; then chown -R terraform:terraform "$WORKDIR" 2>/dev/null || true; fi
: "${OCI_TENANCY_OCID:?OCI_TENANCY_OCID is required}"
: "${OCI_USER_OCID:?OCI_USER_OCID is required}"
: "${OCI_FINGERPRINT:?OCI_FINGERPRINT is required}"
: "${OCI_COMPARTMENT_OCID:?OCI_COMPARTMENT_OCID is required}"
if [ -z "${OCI_PRIVATE_KEY:-}" ] && [ -z "${OCI_PRIVATE_KEY_BASE64:-}" ]; then echo "OCI_PRIVATE_KEY or OCI_PRIVATE_KEY_BASE64 is required" >&2; exit 1; fi
KEY_FILE="$WORKDIR/.oci_api_private_key.pem"
if [ -n "${OCI_PRIVATE_KEY_BASE64:-}" ]; then printf '%s' "$OCI_PRIVATE_KEY_BASE64" | base64 -d > "$KEY_FILE"
elif printf '%s' "$OCI_PRIVATE_KEY" | grep -q 'BEGIN.*PRIVATE KEY'; then printf '%s\n' "$OCI_PRIVATE_KEY" > "$KEY_FILE"
else printf '%s' "$OCI_PRIVATE_KEY" | base64 -d > "$KEY_FILE"
fi
chmod 600 "$KEY_FILE"
TFVARS="$WORKDIR/terraform.tfvars"
KEY_ONELINE=$(sed 's/$/\\n/' "$KEY_FILE" | tr -d '\n' | sed 's/\\n$//')
cat > "$TFVARS" <<EOFVAR
tenancy_ocid         = "${OCI_TENANCY_OCID}"
user_ocid            = "${OCI_USER_OCID}"
api_key_fingerprint  = "${OCI_FINGERPRINT}"
api_key_private_key  = "${KEY_ONELINE}"
compartment_ocid     = "${OCI_COMPARTMENT_OCID}"
EOFVAR
[ -n "${OCI_REGION:-}" ] && echo "region = \"${OCI_REGION}\"" >> "$TFVARS"
[ -n "${OCI_AVAILABILITY_DOMAIN:-}" ] && echo "availability_domain = \"${OCI_AVAILABILITY_DOMAIN}\"" >> "$TFVARS"
[ -n "${OCI_INSTANCE_IMAGE_OCID:-}" ] && echo "instance_image_ocid = \"${OCI_INSTANCE_IMAGE_OCID}\"" >> "$TFVARS"
[ -n "${OCI_SSH_PUBLIC_KEY:-}" ] && echo "ssh_public_key = \"${OCI_SSH_PUBLIC_KEY}\"" >> "$TFVARS"
chmod 600 "$TFVARS"
if [ -n "${TF_BACKEND_TYPE:-}" ]; then
  cat > "$WORKDIR/backend.tf" <<EOF
terraform {
  backend "${TF_BACKEND_TYPE}" {
EOF
  [ -n "${TF_BACKEND_BUCKET:-}" ] && echo "    bucket = \"${TF_BACKEND_BUCKET}\"" >> "$WORKDIR/backend.tf"
  [ -n "${TF_BACKEND_KEY:-}" ] && echo "    key = \"${TF_BACKEND_KEY}\"" >> "$WORKDIR/backend.tf"
  [ -n "${TF_BACKEND_REGION:-}" ] && echo "    region = \"${TF_BACKEND_REGION}\"" >> "$WORKDIR/backend.tf"
  [ -n "${TF_BACKEND_DYNAMODB_TABLE:-}" ] && echo "    dynamodb_table = \"${TF_BACKEND_DYNAMODB_TABLE}\"" >> "$WORKDIR/backend.tf"
  [ -n "${TF_BACKEND_PREFIX:-}" ] && echo "    prefix = \"${TF_BACKEND_PREFIX}\"" >> "$WORKDIR/backend.tf"
  [ -n "${TF_BACKEND_CONN:-}" ] && echo "    conn_str = \"${TF_BACKEND_CONN}\"" >> "$WORKDIR/backend.tf"
  echo "  }" >> "$WORKDIR/backend.tf"
  echo "}" >> "$WORKDIR/backend.tf"
fi
if [ "$(id -u)" = "0" ]; then exec su-exec terraform "$0" "$@"; fi
cd "$WORKDIR"
terraform init -input=false -upgrade
INTERVAL="${RUN_INTERVAL:-300}"
RUN_ONCE="${RUN_ONCE:-0}"
apply_once() {
  echo "[$(date -u +%FT%TZ)] terraform apply start"
  if terraform apply -auto-approve -input=false -var-file="$TFVARS"; then echo "[$(date -u +%FT%TZ)] terraform apply OK"
  else echo "[$(date -u +%FT%TZ)] terraform apply FAILED (will retry next interval)" >&2
  fi
}
if [ "$RUN_ONCE" = "1" ]; then apply_once; exit 0; fi
trap 'echo "[$(date -u +%FT%TZ)] received SIGTERM, exiting"; exit 0' TERM INT
while true; do
  apply_once
  echo "[$(date -u +%FT%TZ)] sleeping ${INTERVAL}s until next run"
  sleep "$INTERVAL" &
  wait $!
done

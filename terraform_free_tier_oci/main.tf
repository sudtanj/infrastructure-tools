terraform {
  required_version = ">= 1.6.0"

  # ---------------------------------------------------------------------------
  # HCP Terraform (cloud backend). Replaces local state entirely.
  # org + workspace names are not secrets — safe to commit.
  # ---------------------------------------------------------------------------
  cloud {}

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# OCI provider
#
# API authentication needs ONLY these four values — no public key is
# required on the Terraform side. OCI already holds the public half of the
# API key pair you generated in the Console; the fingerprint below tells
# OCI which one you're signing with.
#
# These come from HCP Terraform workspace environment variables:
#   TF_VAR_tenancy_ocid
#   TF_VAR_user_ocid
#   TF_VAR_api_key_fingerprint
#   TF_VAR_api_key_private_key   (sensitive)
#   TF_VAR_region
#   TF_VAR_compartment_ocid
# ---------------------------------------------------------------------------
provider "oci" {
  region       = var.region
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.api_key_fingerprint
  private_key  = var.api_key_private_key
}

# --- Dynamic Data Lookups ---

data "oci_identity_availability_domains" "ad" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_vcns" "existing_vcns" {
  compartment_id = var.compartment_ocid
}

data "oci_core_subnets" "public_subnets" {
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_vcns.existing_vcns.virtual_networks[0].id

  filter {
    name   = "prohibit_public_ip_on_vnic"
    values = ["false"]
  }
}

# --- Compute Instance ---

resource "oci_core_instance" "free_tier_instance" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ad.availability_domains[var.availability_domain_index].name
  shape               = "VM.Standard.A1.Flex"
  display_name        = var.instance_name

  source_details {
    source_id               = var.instance_image_ocid
    source_type             = "image"
    boot_volume_size_in_gbs = var.boot_volume_size_in_gbs
  }

  create_vnic_details {
    subnet_id        = data.oci_core_subnets.public_subnets.subnets[0].id
    assign_public_ip = true
  }

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_in_gbs
  }

  # SSH access is OPTIONAL. This key is completely separate from the OCI
  # API key pair — it's what lets you log into the running VM. If you
  # leave var.ssh_public_key empty, the VM is still created, but you'll
  # need Cloud Shell, OCI Bastion, or serial console to get in.
  metadata = var.ssh_public_key != "" ? {
    ssh_authorized_keys = var.ssh_public_key
  } : {}

  lifecycle {
    # Never destroy this VM. Any plan that requires replacement will
    # fail at apply time instead of silently wiping your free-tier slot.
    prevent_destroy = true

    # Ignore drift on fields that should not trigger a replacement:
    #  - source_id: Oracle rotates OL images; without this, every new
    #    image drop would want to destroy+recreate your VM.
    #  - ssh_authorized_keys: keep the original key in metadata even if
    #    the variable changes.
    ignore_changes = [
      source_details[0].source_id,
      metadata["ssh_authorized_keys"],
    ]
  }
}

# --- Outputs ---

output "instance_public_ip" {
  description = "Public IPv4 of the instance"
  value       = oci_core_instance.free_tier_instance.public_ip
}

output "instance_private_ip" {
  description = "Private IPv4 of the instance"
  value       = oci_core_instance.free_tier_instance.private_ip
}

output "instance_id" {
  description = "OCID of the instance"
  value       = oci_core_instance.free_tier_instance.id
}

output "instance_ad" {
  description = "Availability domain the instance landed in"
  value       = oci_core_instance.free_tier_instance.availability_domain
}

output "vcn_id" {
  description = "OCID of the attached VCN"
  value       = data.oci_core_vcns.existing_vcns.virtual_networks[0].id
}

output "subnet_id" {
  description = "OCID of the attached subnet"
  value       = data.oci_core_subnets.public_subnets.subnets[0].id
}
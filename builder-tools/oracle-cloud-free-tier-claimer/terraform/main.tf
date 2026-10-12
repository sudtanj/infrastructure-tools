terraform {
  required_version = ">= 1.6.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

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

data "oci_core_subnets" "existing_subnets" {
  compartment_id = var.compartment_ocid
  vcn_id         = data.oci_core_vcns.existing_vcns.virtual_networks[0].id
}

# Always fetch the latest official Oracle Linux 8 image for ARM (A1.Flex)
data "oci_core_images" "oracle_linux_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# --- Compute Instance (Always Free ARM Ampere) ---

resource "oci_core_instance" "free_tier_instance" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ad.availability_domains[0].name
  shape               = "VM.Standard.A1.Flex"
  display_name        = "oci-free-tier-vm"

  source_details {
    # Strictly use the dynamic lookup result to bypass any bad input variables
    source_id               = data.oci_core_images.oracle_linux_arm.images[0].id
    source_type             = "image"
    boot_volume_size_in_gbs = 50
  }

  create_vnic_details {
    subnet_id        = data.oci_core_subnets.existing_subnets.subnets[0].id
    assign_public_ip = true
  }

  shape_config {
    ocpus         = 2
    memory_in_gbs = 12
  }

  metadata = var.ssh_public_key != "" ? {
    ssh_authorized_keys = var.ssh_public_key
  } : {}
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

output "vcn_id" {
  description = "OCID of the attached VCN"
  value       = data.oci_core_vcns.existing_vcns.virtual_networks[0].id
}

output "subnet_id" {
  description = "OCID of the attached subnet"
  value       = data.oci_core_subnets.existing_subnets.subnets[0].id
}

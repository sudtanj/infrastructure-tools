terraform {
  required_version = ">= 1.6.0"

  cloud {}

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

data "oci_core_images" "oracle_linux_arm" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = "VM.Standard.A1.Flex"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "free_tier_instance" {
  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.ad.availability_domains[var.availability_domain_index].name
  shape               = "VM.Standard.A1.Flex"
  display_name        = var.instance_name

  source_details {
    source_id               = data.oci_core_images.oracle_linux_arm.images[0].id
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

  metadata = var.ssh_public_key != "" ? {
    ssh_authorized_keys = var.ssh_public_key
  } : {}

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      source_details[0].source_id,
      metadata["ssh_authorized_keys"],
    ]
  }
}

output "instance_public_ip" {
  value     = oci_core_instance.free_tier_instance.public_ip
  sensitive = true
}

output "instance_private_ip" {
  value     = oci_core_instance.free_tier_instance.private_ip
  sensitive = true
}

output "instance_id" {
  value     = oci_core_instance.free_tier_instance.id
  sensitive = true
}

output "instance_ad" {
  value     = oci_core_instance.free_tier_instance.availability_domain
  sensitive = true
}

output "vcn_id" {
  value     = data.oci_core_vcns.existing_vcns.virtual_networks[0].id
  sensitive = true
}

output "subnet_id" {
  value     = data.oci_core_subnets.public_subnets.subnets[0].id
  sensitive = true
}
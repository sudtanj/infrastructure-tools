variable "region" {
  type        = string
  description = "Oracle Cloud region"
  default     = "ap-singapore-1"
}

variable "tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy"
  sensitive   = true
}

variable "user_ocid" {
  type        = string
  description = "OCID of the OCI user"
  sensitive   = true
}

variable "api_key_fingerprint" {
  type        = string
  description = "Fingerprint of the OCI API public key"
  sensitive   = true
}

variable "api_key_private_key" {
  type        = string
  description = "Private key content for the OCI API"
  sensitive   = true
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment"
  sensitive   = true
}

variable "availability_domain_index" {
  type        = number
  description = "Availability domain index (0 = AD-1)"
  default     = 0

  validation {
    condition     = var.availability_domain_index >= 0 && var.availability_domain_index <= 2
    error_message = "availability_domain_index must be 0, 1, or 2."
  }
}

variable "instance_name" {
  type        = string
  description = "Display name of the compute instance"
  default     = "oci-free-tier-vm"
}

variable "boot_volume_size_in_gbs" {
  type        = number
  description = "Boot volume size in GB"
  default     = 50
}

variable "instance_ocpus" {
  type        = number
  description = "OCPUs for the A1.Flex instance"
  default     = 2

  validation {
    condition     = var.instance_ocpus >= 1 && var.instance_ocpus <= 4
    error_message = "Always Free A1.Flex allows 1-4 OCPUs."
  }
}

variable "instance_memory_in_gbs" {
  type        = number
  description = "Memory in GB for the A1.Flex instance"
  default     = 12

  validation {
    condition     = var.instance_memory_in_gbs >= 1 && var.instance_memory_in_gbs <= 24
    error_message = "Always Free A1.Flex allows 1-24 GB memory."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Optional SSH public key for VM login"
  default     = ""

  validation {
    condition     = var.ssh_public_key == "" || can(regex("^ssh-(rsa|ed25519|ecdsa)", var.ssh_public_key))
    error_message = "Provide a valid SSH public key or leave empty."
  }
}
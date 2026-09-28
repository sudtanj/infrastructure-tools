variable "region" {
  type        = string
  description = "Oracle Cloud region"
  default     = "ap-singapore-1"
}

variable "tenancy_ocid" {
  type        = string
  sensitive   = true
}

variable "user_ocid" {
  type        = string
  sensitive   = true
}

variable "api_key_fingerprint" {
  type        = string
  sensitive   = true
}

variable "api_key_private_key" {
  type        = string
  sensitive   = true
}

variable "compartment_ocid" {
  type        = string
  sensitive   = true
}

variable "availability_domain_index" {
  type        = number
  description = "Availability domain index. Singapore (ap-singapore-1) has 1 AD → use 0."
  default     = 0

  validation {
    condition     = var.availability_domain_index == 0
    error_message = "ap-singapore-1 has only one availability domain. Set availability_domain_index = 0."
  }
}

variable "instance_name" {
  type        = string
  description = "Display name of the compute instance"
  default     = "oci-free-tier-vm"
}

variable "boot_volume_size_in_gbs" {
  type        = number
  default     = 50
}

variable "instance_ocpus" {
  type    = number
  default = 2

  validation {
    condition     = var.instance_ocpus >= 1 && var.instance_ocpus <= 4
    error_message = "Always Free A1.Flex allows 1-4 OCPUs."
  }
}

variable "instance_memory_in_gbs" {
  type    = number
  default = 12

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
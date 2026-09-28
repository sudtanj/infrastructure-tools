# ===========================================================================
# OCI API credentials
#
# These four values are all the provider needs. There is no "public key"
# input — OCI already has the public half of the API key pair you uploaded
# in the Console. The fingerprint identifies which key you're signing with.
#
# In HCP Terraform: Workspace -> Variables -> Add variable
#   Category = "Environment variable" for all of these.
# ===========================================================================

variable "region" {
  type        = string
  description = "Oracle Cloud region (home region for Always Free)"
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
  description = "Fingerprint of the OCI API public key (visible in Console under User Settings -> API Keys). No public key body is needed."
  sensitive   = true
}

variable "api_key_private_key" {
  type        = string
  description = "Private key content for the OCI API (.pem downloaded when you created the API key)"
  sensitive   = true
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment where resources will be created"
  sensitive   = true
}

# ===========================================================================
# Availability Domain selection (only used on initial creation)
# ===========================================================================

variable "availability_domain_index" {
  type        = number
  description = "Index into the tenancy's availability domains list (0 = AD-1, 1 = AD-2, 2 = AD-3)"
  default     = 0

  validation {
    condition     = var.availability_domain_index >= 0 && var.availability_domain_index <= 2
    error_message = "availability_domain_index must be 0, 1, or 2."
  }
}

# ===========================================================================
# Instance configuration
# ===========================================================================

variable "instance_name" {
  type        = string
  description = "Display name of the compute instance"
  default     = "oci-free-tier-vm"
}

variable "instance_image_ocid" {
  type        = string
  description = "OCID of the Oracle Linux ARM image (pinned)"
  default     = "ocid1.image.oc1.ap-singapore-1.anuweljtfmqd6oy4cj3p2afhnqjsq3l5mnhcxqd6m3mcdllcqiuqosadwy4q"
}

variable "boot_volume_size_in_gbs" {
  type        = number
  description = "Boot volume size in GB (Always Free covers up to 200 GB total)"
  default     = 50
}

variable "instance_ocpus" {
  type        = number
  description = "OCPUs for the A1.Flex instance (Always Free: up to 4 total)"
  default     = 2

  validation {
    condition     = var.instance_ocpus >= 1 && var.instance_ocpus <= 4
    error_message = "Always Free A1.Flex allows 1-4 OCPUs."
  }
}

variable "instance_memory_in_gbs" {
  type        = number
  description = "Memory in GB for the A1.Flex instance (Always Free: up to 24 GB total)"
  default     = 12

  validation {
    condition     = var.instance_memory_in_gbs >= 1 && var.instance_memory_in_gbs <= 24
    error_message = "Always Free A1.Flex allows 1-24 GB memory."
  }
}

# ===========================================================================
# SSH access (OPTIONAL)
#
# This is NOT the OCI API public key. This is a separate SSH key pair you
# generate yourself (with `ssh-keygen`) and use to log into the running VM.
#
# Leave empty to create the VM with no SSH key configured. You'd then need
# OCI Cloud Shell, OCI Bastion, or the serial console to access it.
#
# Provide the contents of ~/.ssh/id_ed25519.pub (the whole single line,
# starting with "ssh-ed25519 ...") if you want SSH login to work.
# ===========================================================================

variable "ssh_public_key" {
  type        = string
  description = "Optional SSH public key for VM login (separate from the OCI API key). Leave empty for no SSH access."
  default     = ""

  validation {
    condition     = var.ssh_public_key == "" || can(regex("^ssh-(rsa|ed25519|ecdsa)", var.ssh_public_key))
    error_message = "Provide a valid SSH public key starting with ssh-rsa, ssh-ed25519, or ssh-ecdsa, or leave empty."
  }
}
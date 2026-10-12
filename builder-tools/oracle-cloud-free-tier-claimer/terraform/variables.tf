variable "region" {
  type        = string
  description = "Oracle Cloud region (Singapore = ap-singapore-1, Always Free eligible)"
  default     = "ap-singapore-1"
}

variable "tenancy_ocid" {
  type        = string
  description = "OCID of the tenancy"
}

variable "user_ocid" {
  type        = string
  description = "OCID of the OCI user"
}

variable "api_key_fingerprint" {
  type        = string
  description = "Fingerprint of the API public key"
}

variable "api_key_private_key" {
  type        = string
  description = "Private key for OCI API"
  sensitive   = true
}

variable "compartment_ocid" {
  type        = string
  description = "OCID of the compartment where resources will be created"
}

variable "availability_domain" {
  type        = string
  description = "Availability domain suffix (e.g., AD-1)"
  default     = "AD-1"
}

variable "instance_image_ocid" {
  type        = string
  description = "OCID of the image for the instance"
  default     = "ocid1.image.oc1.ap-singapore-1.anuweljtfmqd6oy4cj3p2afhnqjsq3l5mnhcxqd6m3mcdllcqiuqosadwy4q"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for instance access"
  default     = ""
}

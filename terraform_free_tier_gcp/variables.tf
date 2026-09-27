variable "gcp_project_id" {
  type        = string
  description = "GCP Project ID"
  default     = null
}

variable "zone" {
  type        = string
  description = "GCP Zone"
  default     = "us-west1-a"
}

variable "tailscale_auth_key" {
  type        = string
  description = "Tailscale reusable or ephemeral auth key"
  sensitive   = true
}

variable "portainer_admin_password_hash" {
  type        = string
  description = "Bcrypt hash for Portainer initial admin password (min 12 chars before hashing)"
  sensitive   = true
}
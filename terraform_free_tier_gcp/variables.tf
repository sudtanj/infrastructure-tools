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
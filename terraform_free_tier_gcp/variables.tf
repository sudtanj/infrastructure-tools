variable "gcp_project_id" {
  type        = string
  description = "The GCP Project ID where resources will be deployed."
}

variable "zone" {
  type        = string
  default     = "us-west1-a" # Always Free Tier eligible region
  description = "GCP compute zone."
}
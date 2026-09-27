terraform {
  required_version = ">= 1.5.0"

  # Dynamic HCP Terraform Remote State Backend
  # Values for organization and workspace are injected via environment variables:
  # - TF_CLOUD_ORGANIZATION
  # - TF_WORKSPACE
  cloud {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.45.3" # Re-signed version post-key rotation (or ~> 6.0)
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

# --- Provider ---
provider "google" {
  project = var.gcp_project_id
  zone    = var.zone
}

# --- Random ID Generator for Collision Prevention ---
resource "random_id" "hex" {
  byte_length = 4
}

# --- Service Account for VM ---
resource "google_service_account" "vm_sa" {
  account_id   = "free-tier-vm-sa-${random_id.hex.hex}"
  display_name = "Free Tier VM Service Account"
}

# --- Local Metadata Configuration ---
locals {
  vm_metadata = {
    user-data = file("${path.module}/cloud-init.yaml")
  }
}

# --- Trigger to force VM recreation when cloud-init changes ---
resource "terraform_data" "cloud_init_trigger" {
  input = hashicorp_md5(file("${path.module}/cloud-init.yaml"))
}

# --- Compute Instance (Container-Optimized OS) ---
resource "google_compute_instance" "free_tier_vm" {
  name                = "gcp-free-tier-vm-${random_id.hex.hex}"
  machine_type        = "e2-micro" # Always Free Tier eligible
  zone                = var.zone
  deletion_protection = false

  tags = ["free-tier-instance"]

  labels = {
    environment = "free-tier"
    managed_by  = "terraform"
  }

  boot_disk {
    initialize_params {
      image = "cos-cloud/cos-stable" # Container-Optimized OS
      size  = 30                     # Max 30 GB pd-standard (Free Tier limit)
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = "default"
    subnetwork = "default"

    stack_type = "IPV4_IPV6"

    # Assign public IPv6 address
    ipv6_access_config {
      network_tier = "PREMIUM"
    }

    # Omitted external access_config block prevents public IPv4 address charges ($0 cost)
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
  }

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  metadata = local.vm_metadata

  lifecycle {
    create_before_destroy = false
    replace_triggered_by  = [terraform_data.cloud_init_trigger]
  }
}

# --- Firewall: Allow IAP SSH Access (IPv4 Ingress for gcloud compute ssh) ---
resource "google_compute_firewall" "allow_iap_ssh" {
  name        = "allow-iap-ssh-${random_id.hex.hex}"
  network     = "default"
  description = "Allow SSH access through GCP Identity-Aware Proxy (IAP)"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Official GCP IAP ingress range
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["free-tier-instance"]
}

# --- Firewall: Allow Portainer Web UI (IPv6) ---
resource "google_compute_firewall" "allow_portainer_ipv6" {
  name        = "allow-portainer-ipv6-${random_id.hex.hex}"
  network     = "default"
  description = "Allow inbound Portainer Web UI access over IPv6"

  allow {
    protocol = "tcp"
    ports    = ["9000", "9443"]
  }

  source_ranges = ["::/0"]
  target_tags   = ["free-tier-instance"]
}

# --- Outputs ---
output "vm_name" {
  value       = google_compute_instance.free_tier_vm.name
  description = "The name of the deployed compute instance."
}

output "instance_ipv6" {
  value       = google_compute_instance.free_tier_vm.network_interface[0].ipv6_access_config[0].external_ipv6
  description = "Public IPv6 address of the instance."
}
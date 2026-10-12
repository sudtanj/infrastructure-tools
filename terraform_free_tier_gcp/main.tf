terraform {
  required_version = ">= 1.5.0"

  # Dynamic HCP Terraform Remote State Backend
  cloud {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.45.3"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

# --- Provider ---
provider "google" {}

# --- Random ID Generator for Collision Prevention ---
resource "random_id" "hex" {
  byte_length = 4
}

# --- Service Account for VM ---
resource "google_service_account" "vm_sa" {
  account_id   = "free-tier-vm-sa-${random_id.hex.hex}"
  display_name = "Free Tier VM Service Account"
}

# --- Render Cloud-Init Template with Secrets ---
locals {
  rendered_cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    tailscale_auth_key            = var.tailscale_auth_key
    portainer_admin_password_hash = var.portainer_admin_password_hash
  })
}

# --- Trigger to force VM recreation when rendered cloud-init changes ---
resource "terraform_data" "cloud_init_trigger" {
  input = sha256(local.rendered_cloud_init)
}

# --- Compute Instance (Container-Optimized OS) ---
resource "google_compute_instance" "free_tier_vm" {
  name                = "gcp-free-tier-vm-${random_id.hex.hex}"
  machine_type        = "e2-micro" # Always Free Tier eligible (us-west1 / us-central1 / us-east1 only)
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

    # IPv4-only: external IPv6 is Premium-tier only, so dropping it forces
    # all internet egress through the Standard tier IP (200 GB/month free).
    stack_type = "IPV4_ONLY"

    # Ephemeral external IPv4 (no nat_ip = ephemeral) on Standard tier
    access_config {
      network_tier = "STANDARD"
    }
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

  metadata = {
    # Masks rendered cloud-init (including secrets) from terraform plan outputs
    user-data = sensitive(local.rendered_cloud_init)
  }

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

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["free-tier-instance"]
}

# --- Firewall: Allow Portainer Web UI (IPv4) ---
# Consider deleting this and reaching Portainer over Tailscale instead.
resource "google_compute_firewall" "allow_portainer_ipv4" {
  name        = "allow-portainer-ipv4-${random_id.hex.hex}"
  network     = "default"
  description = "Allow inbound Portainer Web UI access over IPv4"

  allow {
    protocol = "tcp"
    ports    = ["9443"] # HTTPS only; 9000 is plain HTTP
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["free-tier-instance"]
}

# --- Outputs ---
output "vm_name" {
  value       = google_compute_instance.free_tier_vm.name
  description = "The name of the deployed compute instance."
}

output "instance_ipv4" {
  value       = google_compute_instance.free_tier_vm.network_interface[0].access_config[0].nat_ip
  description = "Ephemeral public IPv4 address of the instance (Standard tier)."
}

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

# ==============================================================================
# Template Rendering & Rebuild Trigger
# ==============================================================================
locals {
  rendered_cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    tailscale_auth_key            = var.tailscale_auth_key
    portainer_admin_password_hash = var.portainer_admin_password_hash
  })
}

# Generates a hash of the rendered cloud-init to trigger instance recreation on config changes
resource "terraform_data" "cloud_init_trigger" {
  input = sha256(local.rendered_cloud_init)
}

# ==============================================================================
# Networking & Security
# ==============================================================================
resource "google_compute_network" "vpc_network" {
  name                    = "free-tier-vpc"
  auto_create_subnetworks = true
}

# Allow GCP IAP (Identity-Aware Proxy) for secure SSH access without public IP exposure
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "allow-iap-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # GCP Identity-Aware Proxy IP range
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["free-tier-vm"]
}

# ==============================================================================
# Compute Instance (GCP Always Free Tier Compliant)
# ==============================================================================
resource "google_compute_instance" "free_tier_vm" {
  name         = "gcp-free-tier-vm"
  machine_type = "e2-micro" # Eligible for GCP Always Free Tier in US regions
  zone         = var.gcp_zone

  tags = ["free-tier-vm"]

  boot_disk {
    auto_delete = true
    initialize_params {
      # Container-Optimized OS (COS) stable image
      image = "cos-cloud/cos-stable"
      size  = 30 # Max free tier disk allocation is 30GB Standard Persistent Disk
      type  = "pd-standard"
    }
  }

  network_interface {
    network = google_compute_network.vpc_network.name

    # Assigns an ephemeral public IP for outbound internet access (required for Tailscale/Docker image pulls)
    access_config {
      network_tier = "STANDARD"
    }
  }

  metadata = {
    # sensitive() masks rendered cloud-init contents (including secrets) from terraform plan outputs
    user-data = sensitive(local.rendered_cloud_init)
  }

  scheduling {
    preemptible       = false
    automatic_restart = true
  }

  lifecycle {
    create_before_destroy = false
    replace_triggered_by  = [terraform_data.cloud_init_trigger]
  }
}

# ==============================================================================
# Outputs
# ==============================================================================
output "instance_name" {
  description = "The name of the VM instance created"
  value       = google_compute_instance.free_tier_vm.name
}

output "instance_id" {
  description = "The server-assigned unique identifier for the instance"
  value       = google_compute_instance.free_tier_vm.instance_id
}
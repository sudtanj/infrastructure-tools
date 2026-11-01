#!/usr/bin/env bash
# One-time host setup for a GCP free-tier e2-micro (1 GB RAM). Run with sudo.
set -euo pipefail
if ! swapon --show | grep -q /swapfile; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
# Prefer RAM, but swap rather than OOM-kill agents.
echo 'vm.swappiness=20' > /etc/sysctl.d/99-paseo.conf && sysctl -p /etc/sysctl.d/99-paseo.conf
# Cap journald growth.
sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=50M/' /etc/systemd/journald.conf && systemctl restart systemd-journald
echo "Done. Free-tier note: e2-micro = us-west1/us-central1/us-east1 only, 30 GB standard PD, 1 GB/month egress."

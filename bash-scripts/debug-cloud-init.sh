#!/bin/bash
# bash-scripts/debug-cloud-init.sh
# Read-only cloud-init diagnostics for a GCE VM (Container-Optimized OS or Ubuntu).
# CHANGES NOTHING. Safe to run any time, locally on the VM or through the workflow.
#
# Output uses the workflow's structured prefixes so every line survives its filter:
#   [*] info   [>] section   [+]/[✓] ok   [!] warning   [x] problem   [d] log excerpt
# It never prints the user-data contents. IPs, emails, tokens and URL credentials are masked
# before anything is printed.
#
# Env:  FULL=1    longer log excerpts (default: short)
#       STRICT=1  exit 1 when a problem is found (default: always exit 0)

set -uo pipefail

FULL="${FULL:-0}"
STRICT="${STRICT:-0}"
N_LOG=40; N_OUT=60
[ "$FULL" = "1" ] && { N_LOG=200; N_OUT=300; }

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo -n"
WARN=0; BAD=0
HINTS=()

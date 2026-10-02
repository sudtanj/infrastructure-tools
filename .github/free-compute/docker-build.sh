#!/usr/bin/env bash
# Docker build task for the free compute broker.
# Runs against the TARGET repo (cwd is the checked-out target).
#
# The built image is NOT pushed anywhere by default -- this verifies the
# image builds. Add a registry login + push here if you actually want the
# artifact published (and set the credentials as secrets in the broker repo).
set -euo pipefail

if [ ! -f Dockerfile ]; then
  echo "::warning::No Dockerfile in target repo; nothing to build."
  exit 0
fi

# Derive a safe tag from the ref (no slashes, no shell metacharacters).
RAW_REF="${TARGET_REF:-latest}"
TAG="$(printf '%s' "$RAW_REF" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-' | cut -c1-120)"
[ -z "$TAG" ] && TAG="latest"

IMAGE="free-compute-preview:${TAG}"
echo "Building $IMAGE"

# buildx gives cross-arch builds and a real cache backend on hosted runners.
docker buildx create --use --name free-compute-builder 2>/dev/null || \
  docker buildx use free-compute-builder 2>/dev/null || true

# GHA layer cache keeps repeat runs cheap. Available on standard runners.
docker buildx build \
  --cache-from "type=gha" \
  --cache-to "type=gha,mode=max" \
  --tag "$IMAGE" \
  --load \
  .

echo "::group::Result"
# Deliberately NOT printing the image table: layer sizes and build output
# hint at the structure of private source.
echo "Image built successfully."
echo "::endgroup::"

echo "Docker build completed (not pushed)."
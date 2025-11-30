#!/bin/bash
# =============================================================================
# Build WhisperLive Docker Image for Salad GPU Deployment
# =============================================================================
# Builds the Salad-optimized WhisperLive image locally
#
# Usage:
#   ./salad/build.sh [--tag TAG] [--no-cache]
#
# Options:
#   --tag TAG     Docker image tag (default: whisperlive-salad:latest)
#   --no-cache    Build without using Docker cache
# =============================================================================

set -euo pipefail

# Default configuration
IMAGE_TAG="${IMAGE_TAG:-whisperlive-salad:latest}"
NO_CACHE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "============================================================================="
echo "  Building WhisperLive for Salad GPU Cloud"
echo "============================================================================="
echo ""
echo "  Image Tag:  $IMAGE_TAG"
echo "  Context:    $REPO_ROOT"
echo "  Dockerfile: salad/Dockerfile.salad"
echo ""

# Change to repo root for build context
cd "$REPO_ROOT"

# Build the image
echo "Starting build..."
echo ""

docker build \
    $NO_CACHE \
    -f salad/Dockerfile.salad \
    -t "$IMAGE_TAG" \
    .

echo ""
echo "============================================================================="
echo "  Build Complete!"
echo "============================================================================="
echo ""
echo "  Image: $IMAGE_TAG"
echo ""
echo "  To test locally (requires NVIDIA GPU):"
echo "    docker run --gpus all -p 9090:9090 -p 9999:9999 $IMAGE_TAG"
echo ""
echo "  To push to registry:"
echo "    ./salad/push.sh --tag $IMAGE_TAG"
echo ""

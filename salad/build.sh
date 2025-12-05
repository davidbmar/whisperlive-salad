#!/bin/bash
# =============================================================================
# Build WhisperLive Docker Image for Salad GPU Deployment
# =============================================================================
# Builds the Salad-optimized WhisperLive image with diarization support
#
# Usage:
#   ./salad/build.sh [--tag TAG] [--no-cache] [--skip-models]
#
# Options:
#   --tag TAG       Docker image tag (default: whisperlive-salad:latest)
#   --no-cache      Build without using Docker cache
#   --skip-models   Skip downloading pyannote models (use existing cache)
#
# Prerequisites:
#   - AWS CLI configured (for S3 access to model cache)
#   - Docker installed and running
# =============================================================================

set -euo pipefail

# Default configuration
IMAGE_TAG="${IMAGE_TAG:-whisperlive-salad:latest}"
NO_CACHE=""
SKIP_MODELS=false
S3_MODEL_PATH="s3://dbm-cf-2-web/bintarball/diarized/latest/huggingface-cache.tar.gz"

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
        --skip-models)
            SKIP_MODELS=true
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

# =============================================================================
# Download pyannote model cache from S3
# =============================================================================
CACHE_DIR="$REPO_ROOT/huggingface-cache"

if [ "$SKIP_MODELS" = false ]; then
    echo "[1/3] Downloading pyannote model cache from S3..."

    # Clean up any existing cache
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"

    # Download and extract
    if aws s3 cp "$S3_MODEL_PATH" - 2>/dev/null | tar -xzf - -C "$CACHE_DIR"; then
        echo "  Downloaded and extracted model cache"
        echo "  Models: $(ls "$CACHE_DIR/hub" 2>/dev/null | grep -c models-- || echo 0) cached"
    else
        echo "  WARNING: Could not download model cache from S3"
        echo "  Building without pre-cached models (will need HF_TOKEN at runtime)"
        # Create empty dir so COPY doesn't fail
        mkdir -p "$CACHE_DIR/hub"
    fi
    echo ""
else
    echo "[1/3] Skipping model download (--skip-models)"
    if [ ! -d "$CACHE_DIR" ]; then
        echo "  WARNING: No existing cache found, creating empty directory"
        mkdir -p "$CACHE_DIR/hub"
    fi
    echo ""
fi

# =============================================================================
# Build the Docker image
# =============================================================================
echo "[2/3] Building Docker image..."
echo ""

docker build \
    $NO_CACHE \
    -f salad/Dockerfile.salad \
    -t "$IMAGE_TAG" \
    .

# =============================================================================
# Cleanup
# =============================================================================
echo ""
echo "[3/3] Cleaning up build artifacts..."
rm -rf "$CACHE_DIR"
echo "  Removed temporary model cache"

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

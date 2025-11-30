#!/bin/bash
# =============================================================================
# Push WhisperLive Docker Image to Container Registry
# =============================================================================
# Pushes the Salad-optimized WhisperLive image to a container registry
#
# Usage:
#   ./salad/push.sh [--tag TAG] [--registry REGISTRY]
#
# Options:
#   --tag TAG           Docker image tag (default: whisperlive-salad:latest)
#   --registry REGISTRY Container registry URL (default: docker.io)
#
# Environment Variables:
#   DOCKER_REGISTRY     Container registry URL
#   DOCKER_USERNAME     Registry username (for login)
#   DOCKER_PASSWORD     Registry password (for login)
#
# Examples:
#   # Push to Docker Hub
#   ./salad/push.sh --tag myorg/whisperlive-salad:v1.0
#
#   # Push to AWS ECR
#   aws ecr get-login-password | docker login --username AWS --password-stdin 123456789.dkr.ecr.us-east-2.amazonaws.com
#   ./salad/push.sh --registry 123456789.dkr.ecr.us-east-2.amazonaws.com --tag whisperlive-salad:v1.0
#
#   # Push to Salad Container Registry
#   ./salad/push.sh --registry registry.salad.com --tag whisperlive-salad:v1.0
# =============================================================================

set -euo pipefail

# Default configuration
IMAGE_TAG="${IMAGE_TAG:-whisperlive-salad:latest}"
REGISTRY="${DOCKER_REGISTRY:-}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "============================================================================="
echo "  Pushing WhisperLive to Container Registry"
echo "============================================================================="
echo ""

# Determine full image path
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_TAG}"
else
    FULL_IMAGE="$IMAGE_TAG"
fi

echo "  Local Image:  $IMAGE_TAG"
echo "  Remote Image: $FULL_IMAGE"
echo ""

# Tag for registry if needed
if [ "$FULL_IMAGE" != "$IMAGE_TAG" ]; then
    echo "Tagging image for registry..."
    docker tag "$IMAGE_TAG" "$FULL_IMAGE"
fi

# Push the image
echo "Pushing image..."
echo ""

docker push "$FULL_IMAGE"

echo ""
echo "============================================================================="
echo "  Push Complete!"
echo "============================================================================="
echo ""
echo "  Image pushed: $FULL_IMAGE"
echo ""
echo "  To deploy on Salad:"
echo "    1. Create a container group on Salad Cloud"
echo "    2. Set image: $FULL_IMAGE"
echo "    3. Configure ports:"
echo "       - 9090 (WebSocket)"
echo "       - 9999 (Health Check)"
echo "    4. Set environment variables:"
echo "       - WHISPER_MODEL=small.en"
echo "       - WHISPER_COMPUTE_TYPE=int8"
echo ""

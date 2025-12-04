#!/bin/bash
# =============================================================================
# Push WhisperLive Docker Image to Container Registry
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Connects to GPU instance where image was built
#   2. Tags image for the target registry
#   3. Pushes image to registry (Docker Hub or ECR)
#
# PREREQUISITES:
#   - Image built on GPU instance (run 025-build-image.sh first)
#   - Docker Hub: DOCKER_USERNAME and DOCKER_PASSWORD set
#   - AWS ECR: AWS credentials configured
#
# Usage: ./scripts/037-push-to-registry.sh [--registry dockerhub|ecr] [--tag TAG]
#
# Examples:
#   ./scripts/037-push-to-registry.sh --registry dockerhub --tag myuser/whisperlive:v1
#   ./scripts/037-push-to-registry.sh --registry ecr
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="037-push-to-registry"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"
start_logging "$SCRIPT_NAME"

# Default options
REGISTRY_TYPE="${REGISTRY_TYPE:-dockerhub}"
REMOTE_TAG=""
SHOW_HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --registry|-r)
            REGISTRY_TYPE="$2"
            shift 2
            ;;
        --tag|-t)
            REMOTE_TAG="$2"
            shift 2
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Show help
if [ "$SHOW_HELP" = true ]; then
    head -25 "$0" | tail -20
    exit 0
fi

echo "============================================================================"
echo "Push WhisperLive Image to Container Registry"
echo "============================================================================"
echo ""

# Load environment
if ! load_env_or_fail; then
    exit 1
fi

# Get GPU IP
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    print_status "error" "Could not get GPU instance IP"
    exit 1
fi

# Get SSH key path
if [[ "$SSH_KEY_NAME" == /* ]]; then
    SSH_KEY_PATH="$SSH_KEY_NAME"
else
    SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
fi

LOCAL_IMAGE="${DOCKER_IMAGE:-whisperlive-salad}:${DOCKER_TAG:-latest}"

print_status "ok" "Configuration loaded"
echo "  GPU IP:       $GPU_IP"
echo "  Local Image:  $LOCAL_IMAGE"
echo "  Registry:     $REGISTRY_TYPE"
echo ""

# ============================================================================
# Configure registry-specific settings
# ============================================================================

case "$REGISTRY_TYPE" in
    dockerhub|docker)
        echo -e "${BLUE}[1/3] Configuring Docker Hub...${NC}"

        if [ -z "${DOCKER_USERNAME:-}" ]; then
            print_status "error" "DOCKER_USERNAME not set"
            echo ""
            echo "Set in .env or export:"
            echo "  export DOCKER_USERNAME=yourusername"
            echo "  export DOCKER_PASSWORD=yourpassword"
            exit 1
        fi

        if [ -z "$REMOTE_TAG" ]; then
            REMOTE_TAG="${DOCKER_USERNAME}/whisperlive-salad:${DOCKER_TAG:-latest}"
        fi

        print_status "ok" "Docker Hub configured"
        echo "  Username:     $DOCKER_USERNAME"
        echo "  Remote Tag:   $REMOTE_TAG"
        echo ""

        # Login on remote
        echo -e "${BLUE}[2/3] Logging into Docker Hub on GPU instance...${NC}"
        if [ -z "${DOCKER_PASSWORD:-}" ]; then
            print_status "error" "DOCKER_PASSWORD not set"
            exit 1
        fi

        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
            "echo '$DOCKER_PASSWORD' | docker login -u '$DOCKER_USERNAME' --password-stdin"
        print_status "ok" "Logged into Docker Hub"
        ;;

    ecr)
        echo -e "${BLUE}[1/3] Configuring AWS ECR...${NC}"

        ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

        if [ -z "$REMOTE_TAG" ]; then
            REMOTE_TAG="${ECR_REGISTRY}/whisperlive-salad:${DOCKER_TAG:-latest}"
        fi

        print_status "ok" "ECR configured"
        echo "  Registry:     $ECR_REGISTRY"
        echo "  Remote Tag:   $REMOTE_TAG"
        echo ""

        # Create ECR repository if it doesn't exist
        echo "Ensuring ECR repository exists..."
        aws ecr describe-repositories --repository-names whisperlive-salad --region "$AWS_REGION" 2>/dev/null || \
            aws ecr create-repository --repository-name whisperlive-salad --region "$AWS_REGION" >/dev/null

        # Login on remote
        echo -e "${BLUE}[2/3] Logging into ECR on GPU instance...${NC}"
        LOGIN_CMD=$(aws ecr get-login-password --region "$AWS_REGION")
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
            "echo '$LOGIN_CMD' | docker login -u AWS --password-stdin $ECR_REGISTRY"
        print_status "ok" "Logged into ECR"
        ;;

    *)
        print_status "error" "Unknown registry type: $REGISTRY_TYPE"
        echo "Supported: dockerhub, ecr"
        exit 1
        ;;
esac

echo ""

# ============================================================================
# Tag and push image
# ============================================================================
echo -e "${BLUE}[3/3] Tagging and pushing image...${NC}"

echo "  Tagging: $LOCAL_IMAGE -> $REMOTE_TAG"
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    "docker tag '$LOCAL_IMAGE' '$REMOTE_TAG'"

echo "  Pushing: $REMOTE_TAG"
echo "  (This may take several minutes for a ~15GB image)"
echo ""

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    "docker push '$REMOTE_TAG'"

echo ""
echo "============================================================================"
print_status "ok" "IMAGE PUSHED SUCCESSFULLY"
echo "============================================================================"
echo ""
echo "  Image: $REMOTE_TAG"
echo ""
echo "To deploy on Salad Cloud:"
echo "  1. Go to https://portal.salad.com"
echo "  2. Create a Container Group"
echo "  3. Set Image: $REMOTE_TAG"
echo "  4. Configure:"
echo "     - GPU: Any NVIDIA (RTX 3080+ recommended)"
echo "     - vCPU: 4+"
echo "     - RAM: 16GB+"
echo "     - Ports: 9090 (WebSocket), 9999 (Health)"
echo "  5. Environment Variables:"
echo "     - WHISPER_MODEL=$WHISPER_MODEL"
echo "     - WHISPER_COMPUTE_TYPE=$WHISPER_COMPUTE_TYPE"
echo "     - MAX_CLIENTS=$MAX_CLIENTS"
echo "  6. Health Check: http://:9999/health"
echo ""
echo "Next: Create 038-deploy-salad.sh for Salad API deployment"
echo ""

#!/bin/bash
# =============================================================================
# Build WhisperLive Docker Image on GPU Instance
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Uses rsync to sync the local repository to the GPU instance at /opt/whisperlive
#   2. Builds the Docker image on the GPU instance using salad/build.sh
#   3. Verifies the image was built successfully
#
# PREREQUISITES:
#   - GPU instance deployed (run 020-deploy-gpu-instance.sh first)
#   - .env file configured with GPU_INSTANCE_ID
#   - SSH access to the GPU instance
#   - rsync installed locally
#
# CONFIGURATION:
#   All settings are read from .env file. The GPU IP is looked up dynamically
#   from GPU_INSTANCE_ID since the IP can change when instance is stopped/started.
#
# Usage: ./scripts/025-build-image.sh [--no-cache] [--help]
#
# Options:
#   --no-cache    Build Docker image without cache (clean rebuild)
#   --help        Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="025-build-image"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Default options
NO_CACHE=""
SHOW_HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-cache)
            NO_CACHE="--no-cache"
            shift
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

# Show help if requested
if [ "$SHOW_HELP" = true ]; then
    head -35 "$0" | tail -30
    exit 0
fi

echo "============================================================================"
echo "Building WhisperLive Docker Image on GPU Instance"
echo "============================================================================"
echo ""

# ============================================================================
# [1/5] Load environment and validate
# ============================================================================
echo -e "${BLUE}[1/5] Loading environment and validating...${NC}"

if ! load_env_or_fail; then
    exit 1
fi

# Validate required variables
if [ -z "${GPU_INSTANCE_ID:-}" ] || [ "$GPU_INSTANCE_ID" = "TO_BE_DISCOVERED" ]; then
    print_status "error" "GPU_INSTANCE_ID not set. Run ./scripts/020-deploy-gpu-instance.sh first"
    exit 1
fi

# Get SSH key path
if [[ "$SSH_KEY_NAME" == /* ]]; then
    SSH_KEY_PATH="$SSH_KEY_NAME"
else
    SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
    print_status "error" "SSH key not found: $SSH_KEY_PATH"
    exit 1
fi

# Look up GPU IP from instance ID (IP can change!)
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    print_status "error" "Could not get GPU instance IP. Is the instance running?"
    echo "Check instance status: ./scripts/850-status.sh"
    echo "Start instance: ./scripts/820-start-gpu-instance.sh"
    exit 1
fi

# Validate SSH connectivity
if ! validate_ssh_connectivity "$GPU_IP" "$SSH_KEY_PATH"; then
    print_status "error" "Cannot connect to GPU instance at $GPU_IP"
    echo "Check instance status: ./scripts/850-status.sh"
    exit 1
fi

print_status "ok" "Environment validated"
echo "  Instance ID: $GPU_INSTANCE_ID"
echo "  GPU IP:      $GPU_IP"
echo "  Image:       ${DOCKER_IMAGE:-whisperlive-salad}:${DOCKER_TAG:-latest}"
echo ""

# ============================================================================
# [2/5] Check prerequisites on remote
# ============================================================================
echo -e "${BLUE}[2/5] Checking prerequisites on GPU instance...${NC}"

# Check docker is available
if ! ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    'docker --version' &>/dev/null; then
    print_status "error" "Docker not available on GPU instance"
    exit 1
fi
print_status "ok" "Docker is available"

# Check GPU availability
if ! check_gpu_availability "$GPU_IP" "$SSH_KEY_PATH"; then
    print_status "error" "GPU not available on instance"
    exit 1
fi
print_status "ok" "GPU is available"

# Check disk space
DISK_SPACE=$(check_remote_disk_space "$GPU_IP" "$SSH_KEY_PATH" 5)
if [ $? -ne 0 ]; then
    print_status "error" "Insufficient disk space: ${DISK_SPACE}GB available (need 5GB+)"
    exit 1
fi
print_status "ok" "Disk space: ${DISK_SPACE}GB available"
echo ""

# ============================================================================
# [3/5] Sync repository via rsync
# ============================================================================
echo -e "${BLUE}[3/5] Syncing repository to GPU instance...${NC}"

# Check rsync is available locally
if ! command -v rsync &>/dev/null; then
    print_status "error" "rsync not installed locally. Install with: sudo apt-get install rsync"
    exit 1
fi

# Create target directory on remote
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    'sudo mkdir -p /opt/whisperlive && sudo chown ubuntu:ubuntu /opt/whisperlive'

# Sync repository (excluding unnecessary files)
echo "Syncing from: $PROJECT_ROOT"
echo "Syncing to:   ubuntu@$GPU_IP:/opt/whisperlive"

rsync -avz --progress \
    --exclude='.git' \
    --exclude='*.pyc' \
    --exclude='__pycache__' \
    --exclude='.env' \
    --exclude='artifacts/' \
    --exclude='logs/' \
    --exclude='.venv/' \
    --exclude='venv/' \
    --exclude='node_modules/' \
    --exclude='.pytest_cache/' \
    --exclude='*.egg-info/' \
    -e "ssh -i $SSH_KEY_PATH -o StrictHostKeyChecking=no" \
    "$PROJECT_ROOT/" \
    ubuntu@"$GPU_IP":/opt/whisperlive/

print_status "ok" "Repository synced"
echo ""

# ============================================================================
# [4/5] Build Docker image
# ============================================================================
echo -e "${BLUE}[4/5] Building Docker image on GPU instance...${NC}"

IMAGE_TAG="${DOCKER_IMAGE:-whisperlive-salad}:${DOCKER_TAG:-latest}"
echo "Building image: $IMAGE_TAG"
if [ -n "$NO_CACHE" ]; then
    echo "Build mode: no-cache (clean rebuild)"
fi
echo ""

# Build the image
BUILD_START=$(date +%s)

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    "cd /opt/whisperlive && ./salad/build.sh --tag '$IMAGE_TAG' $NO_CACHE"

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

print_status "ok" "Docker image built in $(format_duration $BUILD_DURATION)"
echo ""

# ============================================================================
# [5/5] Verify and report
# ============================================================================
echo -e "${BLUE}[5/5] Verifying image...${NC}"

# Check image exists
if ! check_docker_image_exists "$GPU_IP" "$SSH_KEY_PATH" "$IMAGE_TAG"; then
    print_status "error" "Image verification failed: $IMAGE_TAG not found"
    exit 1
fi

# Get image details
IMAGE_INFO=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    "docker images '$IMAGE_TAG' --format '{{.Size}}'" 2>/dev/null || echo "unknown")

print_status "ok" "Image verified: $IMAGE_TAG ($IMAGE_INFO)"
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}Docker Image Built Successfully!${NC}"
echo "============================================================================"
echo ""
echo "  Image:         $IMAGE_TAG"
echo "  Size:          $IMAGE_INFO"
echo "  Build Time:    $(format_duration $BUILD_DURATION)"
echo "  Location:      ubuntu@$GPU_IP:/opt/whisperlive"
echo ""
echo "Next Steps:"
echo "  1. Start WhisperLive:  ./scripts/030-start-whisperlive.sh"
echo "  2. Test endpoints:     ./scripts/035-test-whisperlive.sh"
echo ""

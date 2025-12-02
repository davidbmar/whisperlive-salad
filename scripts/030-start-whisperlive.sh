#!/bin/bash
# =============================================================================
# Start WhisperLive Container on GPU Instance
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Loads configuration from .env file (never hardcodes values)
#   2. Looks up GPU IP from GPU_INSTANCE_ID (IP can change on restart)
#   3. Starts the WhisperLive container with all environment variables
#   4. Waits for health endpoints to confirm service is ready
#
# PREREQUISITES:
#   - GPU instance deployed (run 020-deploy-gpu-instance.sh first)
#   - Docker image built (run 025-build-image.sh first)
#   - .env file configured
#
# CONFIGURATION (from .env):
#   - WHISPER_MODEL: Model to use (tiny.en, base.en, small.en, medium.en)
#   - WHISPER_COMPUTE_TYPE: Precision (int8, float16, float32)
#   - WHISPERLIVE_PORT: WebSocket port (default: 9090)
#   - HEALTH_CHECK_PORT: Health endpoint port (default: 9999)
#   - MAX_CLIENTS: Maximum concurrent connections
#   - MAX_CONNECTION_TIME: Maximum connection duration in seconds
#
# Usage: ./scripts/030-start-whisperlive.sh [--force] [--restart] [--help]
#
# Options:
#   --force     Skip confirmation prompts
#   --restart   Stop and restart existing container
#   --help      Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="030-start-whisperlive"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Default options
FORCE=false
RESTART=false
SHOW_HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --restart|-r)
            RESTART=true
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
    head -40 "$0" | tail -35
    exit 0
fi

echo "============================================================================"
echo "Starting WhisperLive on GPU Instance"
echo "============================================================================"
echo ""

# ============================================================================
# [1/6] Load environment and validate
# ============================================================================
echo -e "${BLUE}[1/6] Loading environment and validating...${NC}"

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

# Set defaults for optional variables
DOCKER_IMAGE="${DOCKER_IMAGE:-whisperlive-salad}"
DOCKER_TAG="${DOCKER_TAG:-latest}"
WHISPER_MODEL="${WHISPER_MODEL:-small.en}"
WHISPER_COMPUTE_TYPE="${WHISPER_COMPUTE_TYPE:-int8}"
WHISPERLIVE_PORT="${WHISPERLIVE_PORT:-9090}"
HEALTH_CHECK_PORT="${HEALTH_CHECK_PORT:-9999}"
MAX_CLIENTS="${MAX_CLIENTS:-4}"
MAX_CONNECTION_TIME="${MAX_CONNECTION_TIME:-600}"

print_status "ok" "Environment loaded"
echo ""
echo "  Instance:      $GPU_INSTANCE_ID"
echo "  GPU IP:        $GPU_IP"
echo "  Image:         $DOCKER_IMAGE:$DOCKER_TAG"
echo "  Model:         $WHISPER_MODEL ($WHISPER_COMPUTE_TYPE)"
echo "  Ports:         WS=$WHISPERLIVE_PORT, Health=$HEALTH_CHECK_PORT"
echo "  Limits:        max_clients=$MAX_CLIENTS, max_time=${MAX_CONNECTION_TIME}s"
echo ""

# ============================================================================
# [2/6] Check container state
# ============================================================================
echo -e "${BLUE}[2/6] Checking container state...${NC}"

CONTAINER_STATUS=$(get_container_status "$GPU_IP" "$SSH_KEY_PATH" "whisperlive")
print_status "info" "Container status: $CONTAINER_STATUS"
echo ""

# ============================================================================
# [3/6] Handle existing container
# ============================================================================
echo -e "${BLUE}[3/6] Handling existing container...${NC}"

if [ "$CONTAINER_STATUS" = "running" ]; then
    if [ "$RESTART" = true ] || [ "$FORCE" = true ]; then
        echo "Stopping running container..."
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
            'docker stop whisperlive' >/dev/null
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
            'docker rm whisperlive' >/dev/null
        print_status "ok" "Existing container stopped and removed"
    else
        print_status "warn" "WhisperLive is already running"
        echo ""
        echo "WebSocket endpoint: ws://$GPU_IP:$WHISPERLIVE_PORT"
        echo "Health endpoint:    http://$GPU_IP:$HEALTH_CHECK_PORT/health"
        echo ""
        echo "To restart, run: ./scripts/030-start-whisperlive.sh --restart"
        exit 0
    fi
elif [ "$CONTAINER_STATUS" = "stopped" ]; then
    echo "Removing stopped container..."
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
        'docker rm whisperlive' >/dev/null
    print_status "ok" "Stopped container removed"
else
    print_status "ok" "No existing container"
fi
echo ""

# ============================================================================
# [4/6] Verify image exists
# ============================================================================
echo -e "${BLUE}[4/6] Verifying Docker image...${NC}"

IMAGE_TAG="$DOCKER_IMAGE:$DOCKER_TAG"
if ! check_docker_image_exists "$GPU_IP" "$SSH_KEY_PATH" "$IMAGE_TAG"; then
    print_status "error" "Docker image not found: $IMAGE_TAG"
    echo ""
    echo "Build the image first: ./scripts/025-build-image.sh"
    exit 1
fi

print_status "ok" "Image found: $IMAGE_TAG"
echo ""

# ============================================================================
# [5/6] Start container
# ============================================================================
echo -e "${BLUE}[5/6] Starting WhisperLive container...${NC}"

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    "docker run -d --gpus all \
        --name whisperlive \
        --restart unless-stopped \
        -p ${WHISPERLIVE_PORT}:9090 \
        -p ${HEALTH_CHECK_PORT}:9999 \
        -e WHISPER_MODEL='${WHISPER_MODEL}' \
        -e WHISPER_COMPUTE_TYPE='${WHISPER_COMPUTE_TYPE}' \
        -e WHISPERLIVE_PORT=9090 \
        -e HEALTH_CHECK_PORT=9999 \
        -e MAX_CLIENTS='${MAX_CLIENTS}' \
        -e MAX_CONNECTION_TIME='${MAX_CONNECTION_TIME}' \
        -e LOG_FORMAT=json \
        ${IMAGE_TAG}" >/dev/null

print_status "ok" "Container started"
echo ""

# ============================================================================
# [6/6] Wait for ready and report
# ============================================================================
echo -e "${BLUE}[6/6] Waiting for WhisperLive to be ready...${NC}"

# Wait for health endpoint (basic container health)
echo -n "  Waiting for health endpoint (30s timeout)"
if wait_for_http_endpoint "http://$GPU_IP:$HEALTH_CHECK_PORT/health" 200 30; then
    print_status "ok" " Health endpoint ready"
else
    print_status "warn" " Health endpoint timeout (container may still be starting)"
fi

# Wait for ready endpoint (WhisperLive accepting connections)
echo -n "  Waiting for model to load (120s timeout)"
if wait_for_http_endpoint "http://$GPU_IP:$HEALTH_CHECK_PORT/ready" 200 120; then
    print_status "ok" " WhisperLive ready"
else
    print_status "warn" " Ready endpoint timeout"
    echo ""
    echo "Model may still be loading. Check logs: ./scripts/870-logs.sh"
fi
echo ""

# ============================================================================
# Success Summary
# ============================================================================
echo "============================================================================"
echo -e "${GREEN}WhisperLive Started Successfully!${NC}"
echo "============================================================================"
echo ""
echo "  Model:         $WHISPER_MODEL ($WHISPER_COMPUTE_TYPE)"
echo "  Max Clients:   $MAX_CLIENTS"
echo "  Max Time:      ${MAX_CONNECTION_TIME}s"
echo ""
echo "Endpoints:"
echo "  WebSocket:     ws://$GPU_IP:$WHISPERLIVE_PORT"
echo "  Health:        http://$GPU_IP:$HEALTH_CHECK_PORT/health"
echo "  Ready:         http://$GPU_IP:$HEALTH_CHECK_PORT/ready"
echo "  Status:        http://$GPU_IP:$HEALTH_CHECK_PORT/status"
echo ""
echo "Next Steps:"
echo "  Test endpoints: ./scripts/035-test-whisperlive.sh"
echo "  View logs:      ./scripts/870-logs.sh"
echo "  Stop service:   ./scripts/040-stop-whisperlive.sh"
echo ""

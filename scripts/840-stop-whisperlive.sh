#!/bin/bash
# Stop WhisperLive container on GPU instance
# Usage: ./scripts/040-stop-whisperlive.sh [--remove]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

REMOVE_CONTAINER=false
if [ "${1:-}" = "--remove" ]; then
    REMOVE_CONTAINER=true
fi

echo "============================================================================"
echo "Stopping WhisperLive on GPU Instance"
echo "============================================================================"

# Load environment
load_env_or_fail

# Get SSH key path
if [[ "$SSH_KEY_NAME" == /* ]]; then
    SSH_KEY_PATH="$SSH_KEY_NAME"
else
    SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
fi

# Get current instance IP
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    print_status "error" "Could not get GPU instance IP. Is the instance running?"
    exit 1
fi

echo "GPU Instance: $GPU_INSTANCE_ID"
echo "GPU IP: $GPU_IP"
echo ""

# Check if container is running
CONTAINER_RUNNING=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    'docker ps -q -f name=whisperlive' 2>/dev/null || echo "")

if [ -n "$CONTAINER_RUNNING" ]; then
    echo "Stopping WhisperLive container..."
    ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" 'docker stop whisperlive'
    print_status "ok" "Container stopped"
else
    print_status "info" "WhisperLive container was not running"
fi

# Remove container if requested
if [ "$REMOVE_CONTAINER" = "true" ]; then
    CONTAINER_EXISTS=$(ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" \
        'docker ps -aq -f name=whisperlive' 2>/dev/null || echo "")

    if [ -n "$CONTAINER_EXISTS" ]; then
        echo "Removing container..."
        ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" 'docker rm whisperlive'
        print_status "ok" "Container removed"
    fi
fi

echo ""
echo "To restart: ./scripts/030-start-whisperlive.sh"

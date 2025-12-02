#!/bin/bash
# View WhisperLive container logs
# Usage: ./scripts/870-logs.sh [-f] [--tail N]
# Examples:
#   ./scripts/870-logs.sh           # Show recent logs
#   ./scripts/870-logs.sh -f        # Follow logs (live)
#   ./scripts/870-logs.sh --tail 50 # Show last 50 lines

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Parse arguments
FOLLOW=""
TAIL="100"

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--follow)
            FOLLOW="-f"
            shift
            ;;
        --tail)
            TAIL="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [-f] [--tail N]"
            exit 1
            ;;
    esac
done

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

# Check if container exists
CONTAINER_EXISTS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    'docker ps -aq -f name=whisperlive' 2>/dev/null || echo "")

if [ -z "$CONTAINER_EXISTS" ]; then
    print_status "error" "WhisperLive container not found"
    echo "Start it with: ./scripts/030-start-whisperlive.sh"
    exit 1
fi

# Show logs
echo "WhisperLive logs from $GPU_IP"
echo "============================================================================"
ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" "docker logs $FOLLOW --tail $TAIL whisperlive"

#!/bin/bash
# SSH into the GPU instance
# Usage: ./scripts/860-ssh.sh [command]
# Examples:
#   ./scripts/860-ssh.sh              # Interactive shell
#   ./scripts/860-ssh.sh nvidia-smi   # Run a command

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

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
    echo "Check status: ./scripts/850-status.sh"
    exit 1
fi

# Run SSH
if [ $# -eq 0 ]; then
    echo "Connecting to GPU instance ($GPU_IP)..."
    exec ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP"
else
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" "$@"
fi

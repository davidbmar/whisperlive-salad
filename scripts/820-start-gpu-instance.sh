#!/bin/bash
# Start the GPU EC2 instance
# Usage: ./scripts/025-start-gpu-instance.sh

set -euo pipefail

SCRIPT_NAME="820-start-gpu-instance"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"
start_logging "$SCRIPT_NAME"

echo "============================================================================"
echo "Starting GPU Instance"
echo "============================================================================"

# Load environment
load_env_or_fail

# Check instance exists
if [ -z "${GPU_INSTANCE_ID:-}" ] || [ "$GPU_INSTANCE_ID" = "TO_BE_DISCOVERED" ]; then
    print_status "error" "No GPU instance configured. Run ./scripts/020-deploy-gpu-instance.sh first"
    exit 1
fi

# Get current state
INSTANCE_STATE=$(get_instance_state "$GPU_INSTANCE_ID")
echo "Instance ID: $GPU_INSTANCE_ID"
echo "Current State: $INSTANCE_STATE"
echo ""

if [ "$INSTANCE_STATE" = "running" ]; then
    GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
    print_status "info" "Instance is already running"
    echo "Public IP: $GPU_IP"
    exit 0
fi

if [ "$INSTANCE_STATE" != "stopped" ]; then
    print_status "warn" "Instance is in state: $INSTANCE_STATE (expected: stopped)"
    exit 1
fi

# Show cost
HOURLY_RATE=$(get_instance_hourly_rate "$GPU_INSTANCE_TYPE")
echo "Instance Type: $GPU_INSTANCE_TYPE"
echo "Hourly Cost: \$$HOURLY_RATE"
echo ""

# Start instance
echo "Starting instance..."
aws ec2 start-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$AWS_REGION" > /dev/null

# Wait for running state
echo "Waiting for instance to start..."
aws ec2 wait instance-running \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$AWS_REGION"

# Get new IP address (changes on each start)
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")

# Update .env with new IP
update_env_file "GPU_INSTANCE_IP" "$GPU_IP"

print_status "ok" "Instance running"
echo "Public IP: $GPU_IP"
echo ""

# Wait for SSH
echo "Waiting for SSH to become available..."
SSH_KEY_PATH="$SSH_KEY_NAME"
if [[ ! "$SSH_KEY_NAME" == /* ]]; then
    SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
fi

MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if validate_ssh_connectivity "$GPU_IP" "$SSH_KEY_PATH" 2>/dev/null; then
        print_status "ok" "SSH ready"
        break
    fi
    sleep 5
    ATTEMPT=$((ATTEMPT + 1))
done

if [ $ATTEMPT -eq $MAX_ATTEMPTS ]; then
    print_status "warn" "SSH timeout - instance may still be initializing"
fi

echo ""
echo "============================================================================"
echo "Next steps:"
echo "  Check status:       ./scripts/850-status.sh"
echo "  Start WhisperLive:  ./scripts/030-start-whisperlive.sh"
echo "  SSH to instance:    ./scripts/860-ssh.sh"
echo "============================================================================"

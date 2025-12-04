#!/bin/bash
# Stop the GPU EC2 instance (to save costs)
# Usage: ./scripts/025-stop-gpu-instance.sh

set -euo pipefail

SCRIPT_NAME="810-stop-gpu-instance"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"
start_logging "$SCRIPT_NAME"

echo "============================================================================"
echo "Stopping GPU Instance"
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

if [ "$INSTANCE_STATE" = "stopped" ]; then
    print_status "info" "Instance is already stopped"
    exit 0
fi

if [ "$INSTANCE_STATE" != "running" ]; then
    print_status "warn" "Instance is in state: $INSTANCE_STATE"
    exit 1
fi

# Show cost savings
HOURLY_RATE=$(get_instance_hourly_rate "$GPU_INSTANCE_TYPE")
echo "Stopping will save \$$HOURLY_RATE/hour"
echo ""

# Confirm
echo -n "Stop the GPU instance? [y/N]: "
read -r response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Stop instance
echo "Stopping instance..."
aws ec2 stop-instances \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$AWS_REGION" > /dev/null

# Wait for stopped state
echo "Waiting for instance to stop..."
aws ec2 wait instance-stopped \
    --instance-ids "$GPU_INSTANCE_ID" \
    --region "$AWS_REGION"

print_status "ok" "Instance stopped"
echo ""
echo "To restart: ./scripts/820-start-gpu-instance.sh"

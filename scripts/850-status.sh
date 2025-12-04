#!/bin/bash
# Check status of GPU instance and WhisperLive
# Usage: ./scripts/850-status.sh

set -euo pipefail

SCRIPT_NAME="850-status"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"
start_logging "$SCRIPT_NAME"

echo "============================================================================"
echo "WhisperLive Deployment Status"
echo "============================================================================"
echo ""

# Load environment
load_env_or_fail

# Get SSH key path
if [[ "$SSH_KEY_NAME" == /* ]]; then
    SSH_KEY_PATH="$SSH_KEY_NAME"
else
    SSH_KEY_PATH="$HOME/.ssh/${SSH_KEY_NAME}.pem"
fi

# Check EC2 instance status
echo -e "${CYAN}EC2 Instance:${NC}"
echo "  Instance ID:   $GPU_INSTANCE_ID"

INSTANCE_STATE=$(get_instance_state "$GPU_INSTANCE_ID")
echo -n "  State:         "
case "$INSTANCE_STATE" in
    running)
        print_status "ok" "$INSTANCE_STATE"
        ;;
    stopped)
        print_status "warn" "$INSTANCE_STATE"
        ;;
    *)
        print_status "error" "$INSTANCE_STATE"
        ;;
esac

# Get current IP if running
if [ "$INSTANCE_STATE" = "running" ]; then
    GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
    echo "  Public IP:     $GPU_IP"
    echo "  Instance Type: $GPU_INSTANCE_TYPE"

    # Show cost info
    HOURLY_RATE=$(get_instance_hourly_rate "$GPU_INSTANCE_TYPE")
    echo "  Hourly Cost:   \$$HOURLY_RATE"

    echo ""
    echo -e "${CYAN}SSH Connectivity:${NC}"
    echo -n "  Status:        "
    if validate_ssh_connectivity "$GPU_IP" "$SSH_KEY_PATH" 2>/dev/null; then
        print_status "ok" "Connected"

        echo ""
        echo -e "${CYAN}GPU:${NC}"
        GPU_INFO=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
            'nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader' 2>/dev/null || echo "unavailable")
        if [ "$GPU_INFO" != "unavailable" ]; then
            echo "  $GPU_INFO"
        else
            print_status "warn" "Could not query GPU"
        fi

        echo ""
        echo -e "${CYAN}Docker:${NC}"
        DOCKER_STATUS=$(ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" \
            'systemctl is-active docker' 2>/dev/null || echo "inactive")
        echo -n "  Service:       "
        if [ "$DOCKER_STATUS" = "active" ]; then
            print_status "ok" "$DOCKER_STATUS"
        else
            print_status "error" "$DOCKER_STATUS"
        fi

        echo ""
        echo -e "${CYAN}WhisperLive Container:${NC}"
        CONTAINER_STATUS=$(ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" \
            'docker ps -f name=whisperlive --format "{{.Status}}"' 2>/dev/null || echo "")
        echo -n "  Status:        "
        if [ -n "$CONTAINER_STATUS" ]; then
            print_status "ok" "$CONTAINER_STATUS"

            # Test WebSocket port
            echo -n "  Port 9090:     "
            HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://$GPU_IP:${WHISPERLIVE_PORT:-9090}/" 2>/dev/null || echo "000")
            if [ "$HTTP_CODE" = "426" ]; then
                print_status "ok" "WebSocket ready (HTTP $HTTP_CODE)"
            else
                print_status "warn" "HTTP $HTTP_CODE"
            fi
        else
            CONTAINER_EXISTS=$(ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" \
                'docker ps -aq -f name=whisperlive' 2>/dev/null || echo "")
            if [ -n "$CONTAINER_EXISTS" ]; then
                print_status "warn" "Stopped"
            else
                print_status "info" "Not deployed"
            fi
        fi
    else
        print_status "error" "Failed"
    fi
else
    echo ""
    print_status "warn" "Instance is not running. Start with: ./scripts/820-start-gpu-instance.sh"
fi

echo ""
echo "============================================================================"
echo -e "${CYAN}Quick Commands:${NC}"
echo "  Start WhisperLive:  ./scripts/030-start-whisperlive.sh"
echo "  Stop WhisperLive:   ./scripts/040-stop-whisperlive.sh"
echo "  View logs:          ./scripts/870-logs.sh"
echo "  SSH to instance:    ./scripts/860-ssh.sh"
echo "============================================================================"

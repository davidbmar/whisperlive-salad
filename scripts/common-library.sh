#!/bin/bash
# Common GPU Management Functions for WhisperLive
# Shared library for GPU instance management scripts
# Version: 1.0.0

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$PROJECT_ROOT/artifacts}"
LOGS_DIR="${LOGS_DIR:-$PROJECT_ROOT/logs}"

# Ensure directories exist
mkdir -p "$ARTIFACTS_DIR" "$LOGS_DIR"

# State files
INSTANCE_FILE="$ARTIFACTS_DIR/instance.json"
STATE_FILE="$ARTIFACTS_DIR/state.json"
COST_FILE="$ARTIFACTS_DIR/cost.json"

# Colors for console output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================================
# JSON Logging
# ============================================================================

json_log() {
    local script="${1:-unknown}"
    local step="${2:-unknown}"
    local status="${3:-ok}"
    local details="${4:-}"
    shift 4 || true

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Build JSON object
    local json='{'
    json+='"ts":"'$timestamp'"'
    json+=',"script":"'$script'"'
    json+=',"step":"'$step'"'
    json+=',"status":"'$status'"'
    json+=',"details":"'$(echo "$details" | sed 's/"/\\"/g')'"'

    # Parse additional key=value pairs
    while [ $# -gt 0 ]; do
        local key="${1%%=*}"
        local value="${1#*=}"
        if [ "$key" != "$1" ]; then
            if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                json+=',"'$key'":'$value
            else
                json+=',"'$key'":"'$(echo "$value" | sed 's/"/\\"/g')'"'
            fi
        fi
        shift
    done

    json+='}'

    # Print to console with color coding
    local color="$NC"
    case "$status" in
        ok) color="$GREEN" ;;
        warn) color="$YELLOW" ;;
        error) color="$RED" ;;
    esac

    echo -e "${color}[$step] $details${NC}" >&2
}

# ============================================================================
# Environment Management
# ============================================================================

load_env_or_fail() {
    if [ ! -f "$ENV_FILE" ]; then
        echo -e "${RED}Configuration file not found: $ENV_FILE${NC}"
        echo "Run: ./scripts/000-questions.sh"
        return 1
    fi

    source "$ENV_FILE"
    json_log "${SCRIPT_NAME:-common}" "load_env" "ok" "Environment loaded from $ENV_FILE"
}

update_env_file() {
    local key="$1"
    local value="$2"
    local temp_file="${ENV_FILE}.tmp.$$"

    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "$temp_file"
    else
        cp "$ENV_FILE" "$temp_file"
        echo "${key}=${value}" >> "$temp_file"
    fi

    # Update ENV_VERSION
    if grep -q "^ENV_VERSION=" "$temp_file"; then
        local current_version=$(grep "^ENV_VERSION=" "$temp_file" | cut -d= -f2)
        local new_version=$((current_version + 1))
        sed -i "s|^ENV_VERSION=.*|ENV_VERSION=${new_version}|" "$temp_file"
    fi

    mv -f "$temp_file" "$ENV_FILE"
}

# ============================================================================
# State Management
# ============================================================================

get_instance_id() {
    local instance_id=""

    if [ -f "$INSTANCE_FILE" ]; then
        instance_id=$(jq -r '.instance_id // empty' "$INSTANCE_FILE" 2>/dev/null || true)
    fi

    if [ -z "$instance_id" ] && [ -n "${GPU_INSTANCE_ID:-}" ]; then
        instance_id="$GPU_INSTANCE_ID"
    fi

    echo "$instance_id"
}

get_instance_state() {
    local instance_id="${1:-$(get_instance_id)}"

    if [ -z "$instance_id" ]; then
        echo "none"
        return
    fi

    local state=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text \
        --region "${AWS_REGION:-us-east-2}" 2>/dev/null || echo "none")

    if [ "$state" = "None" ] || [ "$state" = "null" ]; then
        state="none"
    fi

    echo "$state"
}

get_instance_ip() {
    local instance_id="${1:-$(get_instance_id)}"

    if [ -z "$instance_id" ]; then
        return
    fi

    aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text \
        --region "${AWS_REGION:-us-east-2}" 2>/dev/null || true
}

write_state_cache() {
    local instance_id="${1}"
    local state="${2}"
    local public_ip="${3:-}"
    local private_ip="${4:-}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$STATE_FILE" <<EOF
{
  "instance_id": "$instance_id",
  "state": "$state",
  "public_ip": "$public_ip",
  "private_ip": "$private_ip",
  "last_state_change": "$timestamp",
  "region": "${AWS_REGION:-us-east-2}",
  "instance_type": "${GPU_INSTANCE_TYPE:-unknown}"
}
EOF
}

write_instance_facts() {
    local instance_id="${1}"
    local instance_type="${2}"
    local ami_id="${3:-}"
    local security_group_id="${4:-}"
    local key_name="${5:-}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    cat > "$INSTANCE_FILE" <<EOF
{
  "instance_id": "$instance_id",
  "instance_type": "$instance_type",
  "ami_id": "$ami_id",
  "security_group_id": "$security_group_id",
  "key_name": "$key_name",
  "region": "${AWS_REGION:-us-east-2}",
  "created_at": "$timestamp"
}
EOF
}

# ============================================================================
# AWS Operations
# ============================================================================

ensure_security_group() {
    local sg_name="${1:-whisperlive-sg-${DEPLOYMENT_ID:-default}}"
    local sg_desc="${2:-Security group for WhisperLive server}"

    # Check if exists
    local sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "${AWS_REGION:-us-east-2}" 2>/dev/null || echo "None")

    if [ "$sg_id" != "None" ] && [ "$sg_id" != "null" ] && [ -n "$sg_id" ]; then
        echo "$sg_id"
        return 0
    fi

    # Create new
    sg_id=$(aws ec2 create-security-group \
        --group-name "$sg_name" \
        --description "$sg_desc" \
        --query 'GroupId' \
        --output text \
        --region "${AWS_REGION:-us-east-2}")

    # Add SSH rule
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION:-us-east-2}" &>/dev/null || true

    echo "$sg_id"
}

# ============================================================================
# Health Checks
# ============================================================================

validate_ssh_connectivity() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

    if ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" 'echo "SSH OK"' &>/dev/null; then
        return 0
    else
        return 1
    fi
}

wait_for_cloud_init() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"
    local max_wait="${3:-300}"

    local elapsed=0
    while [ $elapsed -lt $max_wait ]; do
        local status=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
            ubuntu@"$instance_ip" \
            'cloud-init status 2>/dev/null | grep -o "status: .*" | cut -d" " -f2' 2>/dev/null || echo "unknown")

        if [ "$status" = "done" ]; then
            return 0
        elif [ "$status" = "error" ]; then
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    return 1
}

check_gpu_availability() {
    local instance_ip="${1}"
    local ssh_key="${2:-$HOME/.ssh/${SSH_KEY_NAME}.pem}"

    local gpu_info=$(ssh -i "$ssh_key" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null' || echo "")

    if [ -n "$gpu_info" ]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# Cost Tracking
# ============================================================================

get_instance_hourly_rate() {
    local instance_type="${1:-${GPU_INSTANCE_TYPE:-g4dn.xlarge}}"

    case "$instance_type" in
        "g4dn.xlarge") echo "0.526" ;;
        "g4dn.2xlarge") echo "0.752" ;;
        "g4dn.4xlarge") echo "1.204" ;;
        "g5.xlarge") echo "1.006" ;;
        "g5.2xlarge") echo "1.212" ;;
        "p3.2xlarge") echo "3.060" ;;
        *) echo "1.000" ;;
    esac
}

update_cost_metrics() {
    local action="${1}"
    local instance_type="${2:-${GPU_INSTANCE_TYPE:-g4dn.xlarge}}"

    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hourly_rate=$(get_instance_hourly_rate "$instance_type")

    if [ "$action" = "start" ]; then
        cat > "$COST_FILE" <<EOF
{
  "session_start": "$timestamp",
  "hourly_rate_usd": $hourly_rate,
  "instance_type": "$instance_type"
}
EOF
    fi
}

# ============================================================================
# Utility Functions
# ============================================================================

format_duration() {
    local seconds="${1}"

    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

print_status() {
    local status="${1}"
    local message="${2}"

    case "$status" in
        ok|success)
            echo -e "${GREEN}$message${NC}"
            ;;
        warn|warning)
            echo -e "${YELLOW}$message${NC}"
            ;;
        error|fail)
            echo -e "${RED}$message${NC}"
            ;;
        info)
            echo -e "${BLUE}$message${NC}"
            ;;
        *)
            echo "$message"
            ;;
    esac
}

# ============================================================================
# Docker & Container Functions
# ============================================================================

# Check available disk space on remote instance
# Usage: check_remote_disk_space <ip> <ssh_key> [min_gb]
# Returns: available GB on stdout, exit 1 if below min_gb
check_remote_disk_space() {
    local instance_ip="${1}"
    local ssh_key="${2}"
    local min_gb="${3:-5}"

    local available_gb=$(ssh -i "$ssh_key" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        "df -BG /opt 2>/dev/null | tail -1 | awk '{print \$4}' | sed 's/G//'" 2>/dev/null || echo "0")

    # Handle empty or non-numeric result
    if ! [[ "$available_gb" =~ ^[0-9]+$ ]]; then
        available_gb=0
    fi

    echo "$available_gb"

    if [ "$available_gb" -lt "$min_gb" ]; then
        return 1
    fi
    return 0
}

# Check if Docker image exists on remote instance
# Usage: check_docker_image_exists <ip> <ssh_key> <image:tag>
# Returns: 0 if exists, 1 if not
check_docker_image_exists() {
    local instance_ip="${1}"
    local ssh_key="${2}"
    local image="${3}"

    local exists=$(ssh -i "$ssh_key" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        "docker images -q '$image' 2>/dev/null" 2>/dev/null || echo "")

    if [ -n "$exists" ]; then
        return 0
    fi
    return 1
}

# Wait for HTTP endpoint to return expected status
# Usage: wait_for_http_endpoint <url> [expected_status] [timeout_seconds]
# Returns: 0 on success, 1 on timeout
wait_for_http_endpoint() {
    local url="${1}"
    local expected="${2:-200}"
    local timeout="${3:-60}"

    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
        if [ "$status" = "$expected" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        echo -n "."
    done
    echo ""
    return 1
}

# Get container status on remote instance
# Usage: get_container_status <ip> <ssh_key> <container_name>
# Returns: "running", "stopped", or "none"
get_container_status() {
    local instance_ip="${1}"
    local ssh_key="${2}"
    local container="${3}"

    # Check if container is running
    local running=$(ssh -i "$ssh_key" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        "docker ps -q -f name='^${container}\$'" 2>/dev/null || echo "")

    if [ -n "$running" ]; then
        echo "running"
        return 0
    fi

    # Check if container exists but stopped
    local exists=$(ssh -i "$ssh_key" -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
        ubuntu@"$instance_ip" \
        "docker ps -aq -f name='^${container}\$'" 2>/dev/null || echo "")

    if [ -n "$exists" ]; then
        echo "stopped"
    else
        echo "none"
    fi
    return 0
}

# ============================================================================
# Self Test
# ============================================================================

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "WhisperLive Common Functions Library v1.0.0"
    echo "==========================================="
    echo ""
    echo "Available functions:"
    echo "  - Logging: json_log"
    echo "  - Environment: load_env_or_fail, update_env_file"
    echo "  - State: get_instance_id, get_instance_state, get_instance_ip"
    echo "  - AWS: ensure_security_group"
    echo "  - Health: validate_ssh_connectivity, check_gpu_availability"
    echo "  - Docker: check_remote_disk_space, check_docker_image_exists,"
    echo "            wait_for_http_endpoint, get_container_status"
    echo "  - Cost: get_instance_hourly_rate, update_cost_metrics"
    echo "  - Utility: format_duration, print_status"
    echo ""
    echo "To use in your script:"
    echo '  source "$(dirname "$0")/common-library.sh"'
fi

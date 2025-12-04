#!/bin/bash
# Interactive Environment Configuration Script for WhisperLive
# Generates .env file from .env.template

set -e

SCRIPT_NAME="000-questions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

TEMPLATE_FILE=".env.template"
ENV_FILE=".env"
BACKUP_FILE=".env.backup-$(date +%Y%m%d-%H%M%S)"

# Setup logging
LOGS_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOGS_DIR"
LOG_FILE="$LOGS_DIR/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================================"
echo "Log started: $(date)"
echo "Script: $SCRIPT_NAME"
echo "Log file: $LOG_FILE"
echo "============================================================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo "============================================================================"
echo -e "${CYAN}WhisperLive GPU Deployment - Environment Configuration${NC}"
echo "============================================================================"
echo ""
echo -e "${YELLOW}WARNING: Do not commit .env or .env.backup* files to git!${NC}"
echo -e "${YELLOW}         They contain deployment-specific configuration.${NC}"
echo ""

# ============================================================================
# Check for existing GPU instance
# ============================================================================
if [ -f "$ENV_FILE" ]; then
    EXISTING_INSTANCE_ID=$(grep "^GPU_INSTANCE_ID=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)

    if [ -n "$EXISTING_INSTANCE_ID" ] && [ "$EXISTING_INSTANCE_ID" != "TO_BE_DISCOVERED" ]; then
        echo -e "${RED}============================================================================${NC}"
        echo -e "${RED}EXISTING GPU INSTANCE DETECTED${NC}"
        echo -e "${RED}============================================================================${NC}"
        echo ""
        echo -e "Instance ID: ${CYAN}$EXISTING_INSTANCE_ID${NC}"

        # Check instance state via AWS
        INSTANCE_STATE=$(aws ec2 describe-instances \
            --instance-ids "$EXISTING_INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>/dev/null || echo "not-found")

        case "$INSTANCE_STATE" in
            "running")
                echo -e "State: ${GREEN}RUNNING${NC}"
                echo ""
                echo -e "${RED}WARNING: This instance is RUNNING and incurring costs!${NC}"
                echo -e "${RED}         Continuing will ORPHAN this instance.${NC}"
                echo -e "${RED}         You will continue paying ~\$0.53/hour until you terminate it.${NC}"
                echo ""
                echo -e "Recommended actions:"
                echo -e "  ${YELLOW}1. Stop the instance:${NC}     ./scripts/810-stop-gpu-instance.sh"
                echo -e "  ${YELLOW}2. Terminate instance:${NC}    aws ec2 terminate-instances --instance-ids $EXISTING_INSTANCE_ID"
                echo -e "  ${YELLOW}3. Reuse existing:${NC}        Skip this script, use existing deployment"
                ;;
            "stopped")
                echo -e "State: ${YELLOW}STOPPED${NC}"
                echo ""
                echo -e "${YELLOW}WARNING: This instance exists but is stopped.${NC}"
                echo -e "${YELLOW}         Continuing will ORPHAN this instance.${NC}"
                echo -e "${YELLOW}         You will still pay ~\$8/month for EBS storage.${NC}"
                echo ""
                echo -e "Recommended actions:"
                echo -e "  ${YELLOW}1. Terminate instance:${NC}    aws ec2 terminate-instances --instance-ids $EXISTING_INSTANCE_ID"
                echo -e "  ${YELLOW}2. Restart existing:${NC}      ./scripts/820-start-gpu-instance.sh"
                echo -e "  ${YELLOW}3. Continue anyway:${NC}       Old instance will be orphaned"
                ;;
            "terminated"|"not-found")
                echo -e "State: ${GREEN}TERMINATED/NOT FOUND${NC} (safe to proceed)"
                ;;
            *)
                echo -e "State: ${YELLOW}$INSTANCE_STATE${NC}"
                echo ""
                echo -e "${YELLOW}Instance is in transitional state. Wait and try again.${NC}"
                ;;
        esac

        if [ "$INSTANCE_STATE" = "running" ] || [ "$INSTANCE_STATE" = "stopped" ]; then
            echo ""
            echo -e "${RED}============================================================================${NC}"
            read -p "Continue and orphan existing instance? (y/N) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                echo "Aborted. Existing configuration preserved."
                exit 0
            fi
            echo ""
        fi
    fi
fi

# Clear stale artifacts from previous deployment
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"
if [ -d "$ARTIFACTS_DIR" ] && [ "$(ls -A "$ARTIFACTS_DIR" 2>/dev/null)" ]; then
    echo -e "${YELLOW}Clearing previous deployment artifacts:${NC}"
    for f in "$ARTIFACTS_DIR"/*.json; do
        if [ -f "$f" ]; then
            echo -e "  - Removing: $(basename "$f")"
            rm -f "$f"
        fi
    done
    echo ""
fi

# Backup existing .env if it exists
if [ -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}Backing up existing .env to $BACKUP_FILE${NC}"
    cp "$ENV_FILE" "$BACKUP_FILE"
fi

# Copy template
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}Error: $TEMPLATE_FILE not found${NC}"
    exit 1
fi

cp "$TEMPLATE_FILE" "$ENV_FILE"

# ============================================================================
# Helper Functions
# ============================================================================

ask_question() {
    local var_name=$1
    local prompt=$2
    local default=$3
    local value

    if [ -n "$default" ]; then
        # Print prompt to stderr so it doesn't get captured
        echo -e "${BLUE}$prompt ${NC}[${GREEN}$default${NC}]: \c" >&2
        read value
        value=${value:-$default}
    else
        echo -e "${BLUE}$prompt: ${NC}\c" >&2
        read value
        while [ -z "$value" ]; do
            echo -e "${RED}   This field is required.${NC}" >&2
            echo -e "${BLUE}$prompt: ${NC}\c" >&2
            read value
        done
    fi

    echo "$value"
}

detect_aws_account() {
    aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN"
}

detect_aws_region() {
    aws configure get region 2>/dev/null || echo "us-east-2"
}

generate_deployment_id() {
    echo "whisperlive-$(date +%Y%m%d-%H%M%S)"
}

update_env_var() {
    local var_name=$1
    local value=$2

    # Escape special characters for sed
    value=$(echo "$value" | sed 's/[&/\]/\\&/g')

    # Update .env file
    sed -i "s|{{$var_name}}|$value|g" "$ENV_FILE"
}

# ============================================================================
# Question Flow
# ============================================================================

echo ""
echo -e "${CYAN}AWS Configuration${NC}"
echo "============================================================================"

# Detect AWS account
AWS_ACCOUNT_ID=$(detect_aws_account)
if [ "$AWS_ACCOUNT_ID" != "UNKNOWN" ]; then
    echo -e "${GREEN}Detected AWS Account ID: $AWS_ACCOUNT_ID${NC}"
    update_env_var "AWS_ACCOUNT_ID" "$AWS_ACCOUNT_ID"
else
    AWS_ACCOUNT_ID=$(ask_question "AWS_ACCOUNT_ID" "Enter AWS Account ID")
    update_env_var "AWS_ACCOUNT_ID" "$AWS_ACCOUNT_ID"
fi

AWS_REGION=$(detect_aws_region)
AWS_REGION=$(ask_question "AWS_REGION" "AWS Region" "$AWS_REGION")
update_env_var "AWS_REGION" "$AWS_REGION"

echo ""
echo -e "${CYAN}GPU Instance Configuration${NC}"
echo "============================================================================"

GPU_INSTANCE_TYPE=$(ask_question "GPU_INSTANCE_TYPE" "GPU Instance Type (g4dn.xlarge recommended)" "g4dn.xlarge")
update_env_var "GPU_INSTANCE_TYPE" "$GPU_INSTANCE_TYPE"

SSH_KEY_NAME=$(ask_question "SSH_KEY_NAME" "SSH Key Name (must exist in AWS, or will be created)")
update_env_var "SSH_KEY_NAME" "$SSH_KEY_NAME"

EBS_VOLUME_SIZE=$(ask_question "EBS_VOLUME_SIZE" "EBS Volume Size in GB" "100")
update_env_var "EBS_VOLUME_SIZE" "$EBS_VOLUME_SIZE"

EBS_VOLUME_TYPE=$(ask_question "EBS_VOLUME_TYPE" "EBS Volume Type" "gp3")
update_env_var "EBS_VOLUME_TYPE" "$EBS_VOLUME_TYPE"

echo ""
echo -e "${CYAN}WhisperLive Configuration${NC}"
echo "============================================================================"

WHISPER_MODEL=$(ask_question "WHISPER_MODEL" "Whisper Model (tiny.en, base.en, small.en, medium.en)" "small.en")
update_env_var "WHISPER_MODEL" "$WHISPER_MODEL"

WHISPER_COMPUTE_TYPE=$(ask_question "WHISPER_COMPUTE_TYPE" "Compute Type (int8, float16, float32)" "int8")
update_env_var "WHISPER_COMPUTE_TYPE" "$WHISPER_COMPUTE_TYPE"

WHISPERLIVE_PORT=$(ask_question "WHISPERLIVE_PORT" "WhisperLive WebSocket Port" "9090")
update_env_var "WHISPERLIVE_PORT" "$WHISPERLIVE_PORT"

HEALTH_CHECK_PORT=$(ask_question "HEALTH_CHECK_PORT" "Health Check HTTP Port" "9999")
update_env_var "HEALTH_CHECK_PORT" "$HEALTH_CHECK_PORT"

MAX_CLIENTS=$(ask_question "MAX_CLIENTS" "Maximum Concurrent Clients" "4")
update_env_var "MAX_CLIENTS" "$MAX_CLIENTS"

MAX_CONNECTION_TIME=$(ask_question "MAX_CONNECTION_TIME" "Max Connection Time (seconds)" "600")
update_env_var "MAX_CONNECTION_TIME" "$MAX_CONNECTION_TIME"

echo ""
echo -e "${CYAN}Docker Configuration${NC}"
echo "============================================================================"

DOCKER_IMAGE=$(ask_question "DOCKER_IMAGE" "Docker Image Name" "whisperlive-salad")
update_env_var "DOCKER_IMAGE" "$DOCKER_IMAGE"

DOCKER_TAG=$(ask_question "DOCKER_TAG" "Docker Tag" "latest")
update_env_var "DOCKER_TAG" "$DOCKER_TAG"

# ============================================================================
# Auto-Generated Values
# ============================================================================

echo ""
echo -e "${CYAN}Generating deployment metadata...${NC}"

DEPLOYMENT_ID=$(generate_deployment_id)
update_env_var "DEPLOYMENT_ID" "$DEPLOYMENT_ID"

DEPLOYMENT_TIMESTAMP=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
update_env_var "DEPLOYMENT_TIMESTAMP" "$DEPLOYMENT_TIMESTAMP"

# Set placeholders for values discovered by deployment scripts
update_env_var "GPU_INSTANCE_ID" "TO_BE_DISCOVERED"
update_env_var "GPU_INSTANCE_IP" "TO_BE_DISCOVERED"
update_env_var "SECURITY_GROUP_ID" "TO_BE_DISCOVERED"

echo ""
echo "============================================================================"
echo -e "${GREEN}Configuration Complete!${NC}"
echo "============================================================================"
echo ""
echo -e "${CYAN}Configuration saved to: ${NC}$ENV_FILE"
if [ -f "$BACKUP_FILE" ]; then
    echo -e "${CYAN}Previous config backed up to: ${NC}$BACKUP_FILE"
fi
echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo -e "   ${YELLOW}1.${NC} Review .env file: ${CYAN}cat .env${NC}"
echo -e "   ${YELLOW}2.${NC} Deploy GPU instance: ${CYAN}./scripts/020-deploy-gpu-instance.sh${NC}"
echo ""

# Show cost estimate
hourly_rate="0.526"
case "$GPU_INSTANCE_TYPE" in
    "g4dn.xlarge") hourly_rate="0.526" ;;
    "g4dn.2xlarge") hourly_rate="0.752" ;;
    "g4dn.4xlarge") hourly_rate="1.204" ;;
    "g5.xlarge") hourly_rate="1.006" ;;
esac

daily_cost=$(echo "scale=2; $hourly_rate * 24" | bc)
monthly_cost=$(echo "scale=2; $hourly_rate * 24 * 30" | bc)

echo -e "${YELLOW}Cost Estimate for $GPU_INSTANCE_TYPE:${NC}"
echo -e "   Hourly:  \$$hourly_rate"
echo -e "   Daily:   \$$daily_cost (if running 24/7)"
echo -e "   Monthly: \$$monthly_cost (if running 24/7)"
echo ""

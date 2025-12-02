#!/bin/bash
# WhisperLive GPU Instance Deployment Script
# Creates a new EC2 GPU instance for WhisperLive deployment
# Version: 1.0.0

set -euo pipefail

# Script metadata
SCRIPT_NAME="whisperlive-deploy"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# ============================================================================
# Configuration
# ============================================================================

DRY_RUN=false
FORCE=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|--plan)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            SKIP_CONFIRM=true
            shift
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Deploy a new GPU instance for WhisperLive"
            echo ""
            echo "Options:"
            echo "  --dry-run, --plan    Show what would be done without doing it"
            echo "  --force              Force deployment even if instance exists"
            echo "  --yes, -y            Skip confirmation prompts"
            echo "  --help, -h           Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ============================================================================
# Helper Functions
# ============================================================================

get_latest_dl_ami() {
    local region="$1"
    # Search for Deep Learning AMI with PyTorch on Ubuntu (x86_64 only, not ARM64)
    aws ec2 describe-images \
        --owners amazon \
        --filters \
            'Name=name,Values=Deep Learning*Nvidia*AMI*PyTorch*Ubuntu*' \
            'Name=state,Values=available' \
            'Name=architecture,Values=x86_64' \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text \
        --region "$region"
}

create_user_data() {
    cat << 'EOF'
#!/bin/bash
set -e

exec > >(tee -a /var/log/user-data.log)
exec 2>&1

echo "Starting WhisperLive GPU instance setup at $(date)"

# Update system
echo "Updating system packages..."
apt-get update || true
apt-get install -y htop nvtop git python3-pip docker.io || true

# Add ubuntu user to docker group
usermod -aG docker ubuntu || true

# Install Docker Compose
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Clean up any existing NVIDIA repository configurations
echo "Cleaning up existing NVIDIA repositories..."
rm -f /etc/apt/sources.list.d/nvidia-container*
rm -f /usr/share/keyrings/nvidia-container*

# Install NVIDIA Container Toolkit
echo "Installing NVIDIA Container Toolkit..."
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

cat > /etc/apt/sources.list.d/nvidia-container-toolkit.list <<NVIDIA_REPO
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/ubuntu20.04/\$(ARCH) /
NVIDIA_REPO

apt-get update || true
apt-get install -y nvidia-container-toolkit || true

# Configure Docker for NVIDIA runtime
echo "Configuring Docker for NVIDIA runtime..."
nvidia-ctk runtime configure --runtime=docker || true
systemctl restart docker || true

# Create directories
echo "Creating WhisperLive directories..."
mkdir -p /opt/whisperlive/{logs,models,config}
chown -R ubuntu:ubuntu /opt/whisperlive

# Mark initialization complete
echo "$(date): WhisperLive GPU instance initialization complete" > /opt/whisperlive/init-complete
echo "User data script completed at $(date)"
EOF
}

# ============================================================================
# Main Deployment Function
# ============================================================================

deploy_instance() {
    echo -e "${BLUE}WhisperLive GPU Instance Deploy Script v${SCRIPT_VERSION}${NC}"
    echo "============================================================================"

    # Load environment
    if ! load_env_or_fail; then
        exit 1
    fi

    # Validate AWS configuration
    if [ -z "${AWS_REGION:-}" ] || [ -z "${AWS_ACCOUNT_ID:-}" ] || [ -z "${GPU_INSTANCE_TYPE:-}" ] || [ -z "${SSH_KEY_NAME:-}" ]; then
        print_status "error" "Missing AWS configuration in .env file"
        echo "Run: ./scripts/000-questions.sh"
        exit 1
    fi

    # Check for existing instance
    local existing_instance_id=$(get_instance_id)
    if [ -n "$existing_instance_id" ] && [ "$FORCE" = "false" ]; then
        local existing_state=$(get_instance_state "$existing_instance_id")

        if [ "$existing_state" != "none" ] && [ "$existing_state" != "terminated" ]; then
            print_status "error" "Instance already exists: $existing_instance_id (state: $existing_state)"
            echo ""
            echo "Options:"
            echo "  - Use --force to deploy anyway"
            echo "  - Terminate existing instance first"
            exit 1
        fi
    fi

    # Set defaults
    EBS_VOLUME_SIZE=${EBS_VOLUME_SIZE:-100}
    EBS_VOLUME_TYPE=${EBS_VOLUME_TYPE:-gp3}

    # Show configuration
    echo ""
    echo -e "${CYAN}Deployment Configuration:${NC}"
    echo "  AWS Region:      ${AWS_REGION}"
    echo "  Account ID:      ${AWS_ACCOUNT_ID}"
    echo "  Instance Type:   ${GPU_INSTANCE_TYPE}"
    echo "  SSH Key:         ${SSH_KEY_NAME}"
    echo "  EBS Volume:      ${EBS_VOLUME_SIZE}GB (${EBS_VOLUME_TYPE})"
    echo "  Deployment ID:   ${DEPLOYMENT_ID}"

    # Cost estimate
    local hourly_rate=$(get_instance_hourly_rate "${GPU_INSTANCE_TYPE}")
    local daily_cost=$(echo "scale=2; $hourly_rate * 24" | bc)
    local monthly_cost=$(echo "scale=2; $hourly_rate * 24 * 30" | bc)

    echo ""
    echo -e "${YELLOW}Cost Estimate:${NC}"
    echo "  Hourly:  \$$hourly_rate"
    echo "  Daily:   \$$daily_cost"
    echo "  Monthly: \$$monthly_cost"

    # Confirmation prompt
    if [ "$SKIP_CONFIRM" = "false" ] && [ "$DRY_RUN" = "false" ]; then
        echo ""
        echo -e "${YELLOW}This will create a new GPU instance${NC}"
        echo -n "Continue with deployment? [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Deployment cancelled."
            exit 0
        fi
    fi

    # Dry run check
    if [ "$DRY_RUN" = "true" ]; then
        echo ""
        echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
        echo ""
        echo "Would perform:"
        echo "  1. Create/reuse security group"
        echo "  2. Create/reuse SSH key pair"
        echo "  3. Find latest Deep Learning AMI"
        echo "  4. Launch EC2 instance with user data"
        echo "  5. Wait for instance to be running"
        echo "  6. Update .env configuration"
        echo "  7. Run initial health checks"
        exit 0
    fi

    # Start deployment
    echo ""
    echo -e "${BLUE}Starting deployment...${NC}"

    # Step 1: Ensure SSH key exists
    echo -e "${BLUE}[1/7] Setting up SSH key...${NC}"

    # Handle SSH_KEY_NAME being either a full path or just a key name
    local ssh_key_path
    local aws_key_name
    if [[ "$SSH_KEY_NAME" == /* ]]; then
        # It's a full path
        ssh_key_path="$SSH_KEY_NAME"
        # Extract just the key name for AWS (remove path and .pem extension)
        aws_key_name=$(basename "$SSH_KEY_NAME" .pem)
    else
        # It's just a key name
        ssh_key_path="$HOME/.ssh/${SSH_KEY_NAME}.pem"
        aws_key_name="$SSH_KEY_NAME"
    fi

    if [ -f "$ssh_key_path" ]; then
        print_status "ok" "Using existing SSH key: $ssh_key_path"
    else
        # Check if key exists in AWS but not locally
        local key_exists=$(aws ec2 describe-key-pairs \
            --key-names "${aws_key_name}" \
            --region "${AWS_REGION}" \
            --query 'KeyPairs[0].KeyName' \
            --output text 2>/dev/null || echo "None")

        if [ "$key_exists" != "None" ] && [ "$key_exists" != "null" ]; then
            print_status "error" "AWS key pair '${aws_key_name}' exists but local file not found"
            echo ""
            echo "Options:"
            echo "  1. Copy existing key to: $ssh_key_path"
            echo "  2. Delete AWS key: aws ec2 delete-key-pair --key-name ${aws_key_name} --region ${AWS_REGION}"
            echo "  3. Use a different key name in .env"
            exit 1
        else
            # Create new key
            echo "Creating new SSH key pair..."
            mkdir -p "$(dirname "$ssh_key_path")"
            aws ec2 create-key-pair \
                --key-name "${aws_key_name}" \
                --query 'KeyMaterial' \
                --output text \
                --region "${AWS_REGION}" > "$ssh_key_path"

            chmod 400 "$ssh_key_path"
            print_status "ok" "Created SSH key: $ssh_key_path"
        fi
    fi

    # Step 2: Ensure security group exists
    echo -e "${BLUE}[2/7] Setting up security group...${NC}"
    local sg_id=$(ensure_security_group "whisperlive-sg-${DEPLOYMENT_ID}" "Security group for WhisperLive server")

    # Add WhisperLive ports
    echo "Configuring security group rules..."

    # WhisperLive WebSocket port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "${WHISPERLIVE_PORT:-9090}" \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" &>/dev/null || true

    # Health check port
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port "${HEALTH_CHECK_PORT:-9999}" \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" &>/dev/null || true

    print_status "ok" "Security group configured: $sg_id"

    # Step 3: Get AMI
    echo -e "${BLUE}[3/7] Finding Deep Learning AMI...${NC}"
    local ami_id=$(get_latest_dl_ami "${AWS_REGION}")

    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ]; then
        print_status "error" "Failed to find suitable Deep Learning AMI"
        exit 1
    fi

    print_status "ok" "Using AMI: $ami_id"

    # Step 4: Create user data
    echo -e "${BLUE}[4/7] Preparing user data...${NC}"
    local user_data_file="/tmp/whisperlive-user-data-$(date +%s).sh"
    create_user_data > "$user_data_file"
    print_status "ok" "User data script prepared"

    # Step 5: Launch instance
    echo -e "${BLUE}[5/7] Launching EC2 instance...${NC}"
    local launch_time=$(date +%s)

    local instance_id=$(aws ec2 run-instances \
        --image-id "$ami_id" \
        --count 1 \
        --instance-type "${GPU_INSTANCE_TYPE}" \
        --key-name "${aws_key_name}" \
        --security-group-ids "$sg_id" \
        --user-data "file://$user_data_file" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=whisperlive-${DEPLOYMENT_ID}},{Key=Purpose,Value=WhisperLive},{Key=DeploymentId,Value=${DEPLOYMENT_ID}}]" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":'${EBS_VOLUME_SIZE}',"VolumeType":"'${EBS_VOLUME_TYPE}'","DeleteOnTermination":true}}]' \
        --query 'Instances[0].InstanceId' \
        --output text \
        --region "${AWS_REGION}")

    if [ -z "$instance_id" ]; then
        print_status "error" "Failed to launch instance"
        exit 1
    fi

    print_status "ok" "Instance launched: $instance_id"

    # Step 6: Wait for running state
    echo -e "${BLUE}[6/7] Waiting for instance to be running...${NC}"
    aws ec2 wait instance-running \
        --instance-ids "$instance_id" \
        --region "${AWS_REGION}"

    # Get IP address
    local public_ip=$(get_instance_ip "$instance_id")
    local private_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text \
        --region "${AWS_REGION}")

    if [ -z "$public_ip" ] || [ "$public_ip" = "None" ]; then
        print_status "error" "Failed to retrieve public IP address"
        exit 1
    fi

    print_status "ok" "Instance running - Public IP: $public_ip"

    # Update configuration files
    echo "Updating configuration..."
    update_env_file "GPU_INSTANCE_ID" "$instance_id"
    update_env_file "GPU_INSTANCE_IP" "$public_ip"
    update_env_file "SECURITY_GROUP_ID" "$sg_id"

    # Write state files
    write_instance_facts "$instance_id" "${GPU_INSTANCE_TYPE}" "$ami_id" "$sg_id" "${aws_key_name}"
    write_state_cache "$instance_id" "running" "$public_ip" "$private_ip"
    update_cost_metrics "start" "${GPU_INSTANCE_TYPE}"

    # Step 7: Health checks
    echo -e "${BLUE}[7/7] Running initial health checks...${NC}"

    echo -n "  SSH connectivity: "
    local ssh_attempts=0
    local max_ssh_attempts=30

    while [ $ssh_attempts -lt $max_ssh_attempts ]; do
        if validate_ssh_connectivity "$public_ip" "$ssh_key_path"; then
            print_status "ok" "Connected"
            break
        fi
        sleep 10
        ssh_attempts=$((ssh_attempts + 1))
    done

    if [ $ssh_attempts -eq $max_ssh_attempts ]; then
        print_status "warn" "SSH timeout (instance may still be initializing)"
    fi

    # Wait for cloud-init if SSH is working
    if [ $ssh_attempts -lt $max_ssh_attempts ]; then
        echo -n "  Cloud-init: "
        if wait_for_cloud_init "$public_ip" "$ssh_key_path" 300; then
            print_status "ok" "Completed"
        else
            print_status "warn" "Timeout (may still be running)"
        fi

        echo -n "  GPU availability: "
        if check_gpu_availability "$public_ip" "$ssh_key_path"; then
            print_status "ok" "GPU detected"
        else
            print_status "warn" "GPU check failed (may need time to initialize)"
        fi
    fi

    # Calculate deployment time
    local total_time=$(($(date +%s) - launch_time))

    # Clean up
    rm -f "$user_data_file"

    # Success summary
    echo ""
    echo -e "${GREEN}GPU Instance Deployed Successfully!${NC}"
    echo "============================================================================"
    echo "Instance ID:     $instance_id"
    echo "Public IP:       $public_ip"
    echo "Instance Type:   ${GPU_INSTANCE_TYPE}"
    echo "SSH Access:      ssh -i $ssh_key_path ubuntu@$public_ip"
    echo "Deployment Time: $(format_duration $total_time)"
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo "1. SSH into the instance:"
    echo "   ssh -i $ssh_key_path ubuntu@$public_ip"
    echo ""
    echo "2. Build and run WhisperLive container:"
    echo "   cd /opt/whisperlive"
    echo "   # Clone repo and build, or pull pre-built image"
    echo "   docker run --gpus all -p 9090:9090 -p 9999:9999 ${DOCKER_IMAGE:-whisperlive-salad}:${DOCKER_TAG:-latest}"
    echo ""
    echo "3. Test health endpoint:"
    echo "   curl http://$public_ip:${HEALTH_CHECK_PORT:-9999}/health"
    echo ""
}

# ============================================================================
# Execute
# ============================================================================

deploy_instance

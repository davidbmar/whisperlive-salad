# WhisperLive for Salad GPU Cloud

This directory contains the Docker configuration for deploying WhisperLive on Salad GPU Cloud.

## Architecture

The Salad deployment follows a "no SSH" model where all debugging is done via container logs and health endpoints:

```
Client ──WSS──> Edge Box (Caddy) ──WS──> Salad GPU (WhisperLive:9090)
                                              │
                                              └── Health Check (HTTP:9999)
```

## Files

| File | Purpose |
|------|---------|
| `Dockerfile.salad` | Main Dockerfile with health checks and structured logging |
| `entrypoint.sh` | Startup script that logs GPU info before starting WhisperLive |
| `healthcheck.py` | HTTP server on port 9999 for container health monitoring |
| `build.sh` | Build the Docker image locally |
| `push.sh` | Push the image to a container registry |

---

# Step-by-Step Deployment Guide

## Prerequisites

- AWS account with EC2 GPU instance access (g4dn.xlarge recommended)
- Docker Hub account OR AWS ECR access
- Salad Cloud account (https://portal.salad.com)
- SSH key for EC2 access

---

## Phase 1: Test on AWS EC2 GPU Instance

### Step 1.1: Launch EC2 GPU Instance

```bash
# Launch a g4dn.xlarge instance with:
# - AMI: Deep Learning AMI GPU PyTorch (Amazon Linux 2 or Ubuntu)
# - Instance type: g4dn.xlarge ($0.526/hour on-demand)
# - Storage: 100GB gp3
# - Security group: Allow inbound 22 (SSH), 9090 (WebSocket), 9999 (Health)

# Or use AWS CLI:
aws ec2 run-instances \
    --image-id ami-0123456789abcdef0 \
    --instance-type g4dn.xlarge \
    --key-name your-key-name \
    --security-group-ids sg-xxxxxxxxx \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]'
```

### Step 1.2: SSH into EC2 GPU Instance

```bash
# Get instance public IP from AWS Console or CLI
aws ec2 describe-instances --instance-ids i-xxxxx --query 'Reservations[0].Instances[0].PublicIpAddress'

# SSH into the instance
ssh -i ~/.ssh/your-key.pem ubuntu@<GPU_PUBLIC_IP>
```

### Step 1.3: Install Docker and NVIDIA Container Toolkit

```bash
# Update system
sudo apt-get update && sudo apt-get upgrade -y

# Install Docker (if not pre-installed)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker

# Install NVIDIA Container Toolkit
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker

# Verify GPU is accessible
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

### Step 1.4: Clone Repository and Build

```bash
# Clone the repo
git clone https://github.com/davidbmar/whisperlive-salad.git
cd whisperlive-salad

# Build the Docker image
./salad/build.sh

# This will create: whisperlive-salad:latest (~9GB)
```

### Step 1.5: Run and Test Container

```bash
# Run the container with GPU access
docker run --gpus all -p 9090:9090 -p 9999:9999 whisperlive-salad:latest

# You should see structured JSON logs showing:
# - GPU detection (Tesla T4, memory, driver)
# - Python/PyTorch versions
# - CUDA availability
# - Health check server starting
# - WhisperLive server starting
```

### Step 1.6: Test Health Endpoints (from another terminal)

```bash
# SSH into the same instance in a new terminal
ssh -i ~/.ssh/your-key.pem ubuntu@<GPU_PUBLIC_IP>

# Test health check
curl http://localhost:9999/health
# Expected: {"status": "healthy", "timestamp": "..."}

# Test readiness
curl http://localhost:9999/ready
# Expected: {"status": "ready", "whisperlive_port": 9090, ...}

# Test detailed status
curl http://localhost:9999/status
# Expected: Full JSON with GPU info, memory, uptime, etc.
```

### Step 1.7: Test WebSocket Connection

```bash
# Install websocat for testing
sudo apt-get install -y websocat

# Test WebSocket handshake (will fail gracefully - that's expected)
websocat ws://localhost:9090
# The connection will establish, proving WebSocket is working
```

---

## Phase 2: Push to Container Registry

You have two options: Docker Hub (simpler) or AWS ECR (more secure for production).

### Option A: Push to Docker Hub

#### Step 2A.1: Create Docker Hub Account

1. Go to https://hub.docker.com
2. Sign up for a free account
3. Create a repository named `whisperlive-salad`

#### Step 2A.2: Login and Push

```bash
# Login to Docker Hub
docker login
# Enter your Docker Hub username and password

# Tag the image for Docker Hub
docker tag whisperlive-salad:latest YOUR_DOCKERHUB_USERNAME/whisperlive-salad:v1.0

# Push to Docker Hub
docker push YOUR_DOCKERHUB_USERNAME/whisperlive-salad:v1.0

# Example:
docker tag whisperlive-salad:latest davidbmar/whisperlive-salad:v1.0
docker push davidbmar/whisperlive-salad:v1.0
```

### Option B: Push to AWS ECR

#### Step 2B.1: Create ECR Repository

```bash
# Set your AWS region
export AWS_REGION=us-east-2

# Create ECR repository
aws ecr create-repository \
    --repository-name whisperlive-salad \
    --region $AWS_REGION

# Get your AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: $AWS_ACCOUNT_ID"
```

#### Step 2B.2: Login and Push to ECR

```bash
# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Tag for ECR
docker tag whisperlive-salad:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/whisperlive-salad:v1.0

# Push to ECR
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/whisperlive-salad:v1.0
```

#### Step 2B.3: Make ECR Public (for Salad access)

Salad needs to pull from a public registry. Either:

1. **Use Docker Hub** (recommended for Salad)
2. **Create ECR Public Repository**:
   ```bash
   # Create public ECR repository
   aws ecr-public create-repository \
       --repository-name whisperlive-salad \
       --region us-east-1  # Public ECR only in us-east-1

   # Login to public ECR
   aws ecr-public get-login-password --region us-east-1 | \
       docker login --username AWS --password-stdin public.ecr.aws

   # Tag and push
   docker tag whisperlive-salad:latest public.ecr.aws/YOUR_ALIAS/whisperlive-salad:v1.0
   docker push public.ecr.aws/YOUR_ALIAS/whisperlive-salad:v1.0
   ```

---

## Phase 3: Deploy to Salad Cloud

### Step 3.1: Create Salad Account

1. Go to https://portal.salad.com
2. Sign up for an account
3. Add payment method (pay-per-use)

### Step 3.2: Create Container Group

1. Navigate to **Container Groups** → **Create Container Group**

2. **Basic Configuration**:
   - Name: `whisperlive-transcription`
   - Container Image: `davidbmar/whisperlive-salad:v1.0` (or your ECR public URL)

3. **Hardware Requirements**:
   - GPU: Required
   - vCPU: 4+
   - Memory: 16GB+
   - GPU Memory: 8GB+ (for small.en model)

4. **Networking**:
   - Enable Container Gateway: Yes
   - Port: `9090` (WebSocket)
   - Port: `9999` (Health Check)

5. **Environment Variables**:
   ```
   WHISPER_MODEL=small.en
   WHISPER_COMPUTE_TYPE=int8
   MAX_CLIENTS=4
   MAX_CONNECTION_TIME=600
   LOG_FORMAT=json
   ```

6. **Health Check**:
   - Protocol: HTTP
   - Port: 9999
   - Path: `/health`
   - Initial Delay: 120 seconds (model loading time)
   - Interval: 30 seconds
   - Timeout: 10 seconds
   - Failure Threshold: 3

7. **Replicas**:
   - Start with 1 for testing
   - Scale up as needed

### Step 3.3: Deploy and Monitor

1. Click **Deploy**
2. Wait for container to reach "Running" status
3. Note the **Container Gateway URL** (e.g., `xyz123.salad.cloud`)

### Step 3.4: Test Salad Deployment

```bash
# Test health endpoint
curl https://xyz123.salad.cloud:9999/health

# Test status endpoint
curl https://xyz123.salad.cloud:9999/status

# WebSocket URL for your Edge Box:
# wss://xyz123.salad.cloud:9090
```

### Step 3.5: Update Edge Box Caddy Configuration

Update your Edge Box to proxy to Salad instead of EC2 GPU:

```bash
# On your Edge Box, edit Caddyfile
sudo nano /opt/whisperlive/Caddyfile

# Change the reverse_proxy target:
# FROM: reverse_proxy ws://EC2_GPU_IP:9090
# TO:   reverse_proxy wss://xyz123.salad.cloud:9090
```

---

## Environment Variables Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_MODEL` | `small.en` | Faster-Whisper model (tiny.en, base.en, small.en, medium.en) |
| `WHISPER_COMPUTE_TYPE` | `int8` | Precision (int8, int8_float16, float16, float32) |
| `WHISPERLIVE_PORT` | `9090` | WebSocket server port |
| `HEALTH_CHECK_PORT` | `9999` | Health check HTTP port |
| `MAX_CLIENTS` | `4` | Maximum concurrent WebSocket clients |
| `MAX_CONNECTION_TIME` | `600` | Max connection duration (seconds) |
| `LOG_FORMAT` | `json` | Log format (json or text) |

---

## Health Check Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Basic health check (always returns 200 if server is running) |
| `GET /ready` | Readiness check (returns 200 only when WhisperLive is accepting connections) |
| `GET /status` | Detailed status with GPU info, memory usage, and configuration |

### Example `/status` Response

```json
{
  "status": "healthy",
  "uptime_seconds": 3600,
  "startup_time": "2025-11-30T10:00:00Z",
  "whisperlive": {
    "ready": true,
    "port": 9090
  },
  "gpu": {
    "name": "Tesla T4",
    "memory_total_mb": 15360,
    "memory_used_mb": 4096,
    "memory_free_mb": 11264,
    "temperature_c": 45,
    "utilization_percent": 20
  },
  "environment": {
    "WHISPER_MODEL": "small.en",
    "WHISPER_COMPUTE_TYPE": "int8"
  }
}
```

---

## Debugging Without SSH

Since Salad containers don't have SSH access, use these methods:

### 1. Salad Portal Logs

- Go to Container Groups → Your Container → Logs
- View real-time structured JSON logs

### 2. Health Endpoints

```bash
# Check if container is healthy
curl https://your-salad-endpoint:9999/health

# Get detailed status with GPU info
curl https://your-salad-endpoint:9999/status
```

### 3. Startup Log Messages

The entrypoint script logs comprehensive information at startup:
- GPU model, memory, driver version
- Python and PyTorch versions
- CUDA availability
- Environment configuration

Example startup logs:
```json
{"timestamp":"2025-11-30T10:00:00.000Z","level":"INFO","component":"entrypoint","message":"Container starting"}
{"timestamp":"2025-11-30T10:00:01.000Z","level":"INFO","component":"entrypoint","message":"GPU: Tesla T4, 15360, 450.80.02, 7.5"}
{"timestamp":"2025-11-30T10:00:02.000Z","level":"INFO","component":"healthcheck","message":"Health check server starting on port 9999"}
{"timestamp":"2025-11-30T10:00:05.000Z","level":"INFO","component":"entrypoint","message":"Starting WhisperLive server on port 9090..."}
```

---

## Model Recommendations

| Use Case | Model | Compute Type | GPU Memory | Speed |
|----------|-------|--------------|------------|-------|
| Fastest | `tiny.en` | `int8` | ~1GB | 4-5x baseline |
| Balanced | `base.en` | `int8` | ~2GB | 2-3x baseline |
| Production | `small.en` | `int8` | ~4GB | 1.5x baseline |
| Best Quality | `medium.en` | `int8` | ~8GB | Baseline |

---

## Cost Comparison

| Platform | Instance/Config | Hourly Cost | Notes |
|----------|-----------------|-------------|-------|
| AWS EC2 On-Demand | g4dn.xlarge | $0.526/hr | Full control, SSH access |
| AWS EC2 Spot | g4dn.xlarge | ~$0.16/hr | Can be interrupted |
| Salad Cloud | Consumer GPU | ~$0.10-0.20/hr | No SSH, pay-per-use |

---

## Troubleshooting

### Container won't start on Salad

1. Check image is publicly accessible
2. Verify health check settings (increase initial delay)
3. Check Salad portal logs for errors

### WebSocket connection fails

1. Verify port 9090 is exposed in Container Gateway
2. Check `/ready` endpoint returns 200
3. Verify Edge Box Caddy config points to correct URL

### GPU not detected

1. Check Salad container has GPU requirement set
2. View startup logs for CUDA availability message
3. Check `/status` endpoint for GPU info

### Model loading timeout

1. Increase health check initial delay to 180s
2. Use smaller model (base.en instead of small.en)
3. Check GPU memory in `/status` response

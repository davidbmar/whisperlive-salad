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

## Quick Start

### 1. Build the Image

```bash
# From the whisperlive-fork root directory
./salad/build.sh

# Or with a custom tag
./salad/build.sh --tag myorg/whisperlive:v1.0
```

### 2. Test Locally (requires NVIDIA GPU)

```bash
docker run --gpus all -p 9090:9090 -p 9999:9999 whisperlive-salad:latest
```

### 3. Push to Registry

```bash
# Push to Docker Hub
./salad/push.sh --tag myorg/whisperlive-salad:v1.0

# Push to AWS ECR
aws ecr get-login-password | docker login --username AWS --password-stdin 123456789.dkr.ecr.us-east-2.amazonaws.com
./salad/push.sh --registry 123456789.dkr.ecr.us-east-2.amazonaws.com --tag whisperlive-salad:v1.0
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_MODEL` | `small.en` | Faster-Whisper model (tiny.en, base.en, small.en, medium.en) |
| `WHISPER_COMPUTE_TYPE` | `int8` | Precision (int8, int8_float16, float16, float32) |
| `WHISPERLIVE_PORT` | `9090` | WebSocket server port |
| `HEALTH_CHECK_PORT` | `9999` | Health check HTTP port |
| `MAX_CLIENTS` | `4` | Maximum concurrent WebSocket clients |
| `MAX_CONNECTION_TIME` | `600` | Max connection duration (seconds) |
| `LOG_FORMAT` | `json` | Log format (json or text) |

## Health Check Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /health` | Basic health check (always returns 200 if server is running) |
| `GET /ready` | Readiness check (returns 200 only when WhisperLive is accepting connections) |
| `GET /status` | Detailed status with GPU info, memory usage, and configuration |

### Example Response from `/status`

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

## Salad Deployment

1. **Create Container Group** on Salad Cloud
2. **Set Image**: `your-registry/whisperlive-salad:v1.0`
3. **Configure Ports**:
   - 9090 (WebSocket - primary)
   - 9999 (Health Check)
4. **Set Environment Variables** as needed
5. **Configure Health Check**:
   - Protocol: HTTP
   - Port: 9999
   - Path: `/health`
   - Interval: 30s
   - Timeout: 10s

## Debugging Without SSH

Since Salad containers don't have SSH access, use these methods:

### 1. Structured Logs

All logs are JSON-formatted for easy parsing:

```json
{"timestamp":"2025-11-30T10:00:00.000Z","level":"INFO","component":"entrypoint","message":"GPU: Tesla T4, 15360, 450.80.02, 7.5"}
```

### 2. Health Endpoints

```bash
# Check if container is healthy
curl https://your-salad-endpoint:9999/health

# Get detailed status with GPU info
curl https://your-salad-endpoint:9999/status
```

### 3. Startup Logs

The entrypoint script logs comprehensive information at startup:
- GPU model, memory, driver version
- Python and PyTorch versions
- CUDA availability
- Environment configuration

## Model Recommendations

| Use Case | Model | Compute Type | Speed |
|----------|-------|--------------|-------|
| Fastest | `tiny.en` | `int8` | 4-5x baseline |
| Balanced | `base.en` | `int8` | 2-3x baseline |
| Production | `small.en` | `int8` | 1.5x baseline |
| Best Quality | `medium.en` | `int8` | Baseline |

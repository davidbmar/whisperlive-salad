#!/bin/bash
# =============================================================================
# WhisperLive Entrypoint for Salad GPU Deployment
# =============================================================================
# This script:
# 1. Logs GPU information at startup (for debugging without SSH)
# 2. Starts the health check server in background
# 3. Launches WhisperLive server
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Logging Helper
# -----------------------------------------------------------------------------
log_json() {
    local level="$1"
    local message="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    if [ "${LOG_FORMAT:-json}" = "json" ]; then
        echo "{\"timestamp\":\"$timestamp\",\"level\":\"$level\",\"component\":\"entrypoint\",\"message\":\"$message\"}"
    else
        echo "[$level] $message"
    fi
}

# -----------------------------------------------------------------------------
# Startup Banner
# -----------------------------------------------------------------------------
echo "============================================================================="
echo "  WhisperLive for Salad GPU Cloud"
echo "  Starting container..."
echo "============================================================================="
echo ""

log_json "INFO" "Container starting"

# -----------------------------------------------------------------------------
# Environment Info
# -----------------------------------------------------------------------------
log_json "INFO" "Environment configuration:"
echo "  WHISPER_MODEL:        ${WHISPER_MODEL:-small.en}"
echo "  WHISPER_COMPUTE_TYPE: ${WHISPER_COMPUTE_TYPE:-int8}"
echo "  WHISPERLIVE_PORT:     ${WHISPERLIVE_PORT:-9090}"
echo "  HEALTH_CHECK_PORT:    ${HEALTH_CHECK_PORT:-9999}"
echo "  LOG_FORMAT:           ${LOG_FORMAT:-json}"
echo ""

# -----------------------------------------------------------------------------
# GPU Detection
# -----------------------------------------------------------------------------
log_json "INFO" "Detecting GPU..."

if command -v nvidia-smi &> /dev/null; then
    echo "--- GPU Information ---"
    nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv,noheader | while read line; do
        log_json "INFO" "GPU: $line"
    done
    echo ""

    # Full nvidia-smi output for debugging
    echo "--- Full nvidia-smi Output ---"
    nvidia-smi
    echo ""
else
    log_json "WARN" "nvidia-smi not found - GPU detection unavailable"
fi

# -----------------------------------------------------------------------------
# Python Environment
# -----------------------------------------------------------------------------
log_json "INFO" "Python environment:"
echo "  Python:  $(python --version 2>&1)"
echo "  Pip:     $(pip --version 2>&1)"
echo ""

# Verify CUDA availability
log_json "INFO" "Checking CUDA availability..."
python -c "import torch; print(f'  PyTorch: {torch.__version__}'); print(f'  CUDA available: {torch.cuda.is_available()}'); print(f'  CUDA devices: {torch.cuda.device_count()}')" 2>/dev/null || log_json "WARN" "PyTorch CUDA check failed"
echo ""

# -----------------------------------------------------------------------------
# Start Health Check Server
# -----------------------------------------------------------------------------
log_json "INFO" "Starting health check server on port ${HEALTH_CHECK_PORT:-9999}..."
python /app/healthcheck.py &
HEALTH_PID=$!
log_json "INFO" "Health check server started (PID: $HEALTH_PID)"

# Give health check server time to start
sleep 2

# Verify health check is running
if kill -0 $HEALTH_PID 2>/dev/null; then
    log_json "INFO" "Health check server running"
else
    log_json "ERROR" "Health check server failed to start"
    exit 1
fi

# -----------------------------------------------------------------------------
# Start WhisperLive Server
# -----------------------------------------------------------------------------
log_json "INFO" "Starting WhisperLive server on port ${WHISPERLIVE_PORT:-9090}..."
echo "============================================================================="
echo "  WhisperLive Server Starting"
echo "  WebSocket endpoint: ws://0.0.0.0:${WHISPERLIVE_PORT:-9090}"
echo "  Health check: http://0.0.0.0:${HEALTH_CHECK_PORT:-9999}/health"
echo "============================================================================="
echo ""

# Build command with environment variables
# Note: run_server.py uses command line args, not env vars
# We pass them appropriately
exec python /app/run_server.py \
    --port "${WHISPERLIVE_PORT:-9090}" \
    --backend "faster_whisper" \
    --max_clients "${MAX_CLIENTS:-4}" \
    --max_connection_time "${MAX_CONNECTION_TIME:-600}"

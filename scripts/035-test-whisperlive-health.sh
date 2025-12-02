#!/bin/bash
# =============================================================================
# Test WhisperLive Health Endpoints
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Tests /health endpoint - basic container health
#   2. Tests /ready endpoint - WhisperLive accepting connections
#   3. Tests /status endpoint - detailed GPU and configuration info
#   4. Reports pass/fail status for each endpoint
#
# PREREQUISITES:
#   - WhisperLive container running (run 030-start-whisperlive.sh first)
#   - .env file configured with GPU_INSTANCE_ID
#
# CONFIGURATION:
#   All settings are read from .env file. The GPU IP is looked up dynamically
#   from GPU_INSTANCE_ID since the IP can change when instance is stopped/started.
#
# Usage: ./scripts/035-test-whisperlive.sh [--verbose] [--json] [--help]
#
# Options:
#   --verbose   Show full response bodies
#   --json      Output results as JSON
#   --help      Show this help message
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="035-test-whisperlive"
SCRIPT_VERSION="1.0.0"

# Load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

# Default options
VERBOSE=false
JSON_OUTPUT=false
SHOW_HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --json|-j)
            JSON_OUTPUT=true
            shift
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Show help if requested
if [ "$SHOW_HELP" = true ]; then
    head -30 "$0" | tail -25
    exit 0
fi

# ============================================================================
# Load environment
# ============================================================================
if ! load_env_or_fail 2>/dev/null; then
    if [ "$JSON_OUTPUT" = true ]; then
        echo '{"error": "Failed to load .env file"}'
    else
        print_status "error" "Failed to load .env file"
    fi
    exit 1
fi

# Validate required variables
if [ -z "${GPU_INSTANCE_ID:-}" ] || [ "$GPU_INSTANCE_ID" = "TO_BE_DISCOVERED" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
        echo '{"error": "GPU_INSTANCE_ID not set"}'
    else
        print_status "error" "GPU_INSTANCE_ID not set. Run ./scripts/020-deploy-gpu-instance.sh first"
    fi
    exit 1
fi

# Look up GPU IP from instance ID (IP can change!)
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    if [ "$JSON_OUTPUT" = true ]; then
        echo '{"error": "Could not get GPU instance IP"}'
    else
        print_status "error" "Could not get GPU instance IP. Is the instance running?"
    fi
    exit 1
fi

# Set defaults for optional variables
HEALTH_CHECK_PORT="${HEALTH_CHECK_PORT:-9999}"
WHISPERLIVE_PORT="${WHISPERLIVE_PORT:-9090}"

# ============================================================================
# Test endpoints
# ============================================================================

# Test result tracking
HEALTH_PASS=false
READY_PASS=false
STATUS_PASS=false
HEALTH_CODE=""
READY_CODE=""
STATUS_CODE=""
STATUS_RESPONSE=""

# Function to test an endpoint
test_endpoint() {
    local url="$1"
    local name="$2"
    local tmpfile="/tmp/healthcheck_response_$$"

    local start_time=$(date +%s%N)
    # Get HTTP code and save body to temp file
    local code=$(curl -s -o "$tmpfile" -w "%{http_code}" --max-time 10 "$url" 2>/dev/null || echo "000")
    local end_time=$(date +%s%N)

    local body=""
    if [ -f "$tmpfile" ]; then
        body=$(cat "$tmpfile")
        rm -f "$tmpfile"
    fi

    local time_ms=$(( (end_time - start_time) / 1000000 ))

    echo "${code}|${time_ms}|${body}"
}

if [ "$JSON_OUTPUT" != true ]; then
    echo "============================================================================"
    echo "WhisperLive Health Check"
    echo "============================================================================"
    echo ""
    echo "  Instance: $GPU_INSTANCE_ID"
    echo "  GPU IP:   $GPU_IP"
    echo "  Ports:    WS=$WHISPERLIVE_PORT, Health=$HEALTH_CHECK_PORT"
    echo ""
    echo "Testing endpoints..."
    echo ""
fi

# [1/3] Test /health endpoint
RESULT=$(test_endpoint "http://$GPU_IP:$HEALTH_CHECK_PORT/health" "health")
HEALTH_CODE=$(echo "$RESULT" | head -1 | cut -d'|' -f1)
HEALTH_TIME=$(echo "$RESULT" | head -1 | cut -d'|' -f2)
HEALTH_BODY=$(echo "$RESULT" | head -1 | cut -d'|' -f3-)
# Append remaining lines to body
HEALTH_BODY="${HEALTH_BODY}
$(echo "$RESULT" | tail -n +2)"

if [ "$HEALTH_CODE" = "200" ]; then
    HEALTH_PASS=true
    if [ "$JSON_OUTPUT" != true ]; then
        print_status "ok" "[1/3] /health - PASS (${HEALTH_TIME}ms)"
    fi
else
    if [ "$JSON_OUTPUT" != true ]; then
        print_status "error" "[1/3] /health - FAIL (HTTP $HEALTH_CODE)"
    fi
fi

if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" != true ]; then
    echo "      Response: $HEALTH_BODY"
fi

# [2/3] Test /ready endpoint
RESULT=$(test_endpoint "http://$GPU_IP:$HEALTH_CHECK_PORT/ready" "ready")
READY_CODE=$(echo "$RESULT" | head -1 | cut -d'|' -f1)
READY_TIME=$(echo "$RESULT" | head -1 | cut -d'|' -f2)
READY_BODY=$(echo "$RESULT" | head -1 | cut -d'|' -f3-)
READY_BODY="${READY_BODY}
$(echo "$RESULT" | tail -n +2)"

if [ "$READY_CODE" = "200" ]; then
    READY_PASS=true
    if [ "$JSON_OUTPUT" != true ]; then
        print_status "ok" "[2/3] /ready - PASS (${READY_TIME}ms)"
    fi
else
    if [ "$JSON_OUTPUT" != true ]; then
        if [ "$READY_CODE" = "503" ]; then
            print_status "warn" "[2/3] /ready - NOT READY (HTTP 503 - model still loading?)"
        else
            print_status "error" "[2/3] /ready - FAIL (HTTP $READY_CODE)"
        fi
    fi
fi

if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" != true ]; then
    echo "      Response: $READY_BODY"
fi

# [3/3] Test /status endpoint
RESULT=$(test_endpoint "http://$GPU_IP:$HEALTH_CHECK_PORT/status" "status")
STATUS_CODE=$(echo "$RESULT" | head -1 | cut -d'|' -f1)
STATUS_TIME=$(echo "$RESULT" | head -1 | cut -d'|' -f2)
STATUS_BODY=$(echo "$RESULT" | head -1 | cut -d'|' -f3-)
STATUS_BODY="${STATUS_BODY}
$(echo "$RESULT" | tail -n +2)"
STATUS_RESPONSE="$STATUS_BODY"

if [ "$STATUS_CODE" = "200" ]; then
    STATUS_PASS=true
    if [ "$JSON_OUTPUT" != true ]; then
        print_status "ok" "[3/3] /status - PASS (${STATUS_TIME}ms)"
    fi
else
    if [ "$JSON_OUTPUT" != true ]; then
        print_status "error" "[3/3] /status - FAIL (HTTP $STATUS_CODE)"
    fi
fi

if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" != true ]; then
    echo "      Response: $STATUS_BODY"
fi

# ============================================================================
# Parse status response for details
# ============================================================================

GPU_NAME="unknown"
GPU_MEM_USED="?"
GPU_MEM_TOTAL="?"
MODEL_NAME="${WHISPER_MODEL:-unknown}"
COMPUTE_TYPE="${WHISPER_COMPUTE_TYPE:-unknown}"
UPTIME_SECONDS="0"

if [ "$STATUS_PASS" = true ] && command -v jq &>/dev/null; then
    GPU_NAME=$(echo "$STATUS_RESPONSE" | jq -r '.gpu.name // "unknown"' 2>/dev/null || echo "unknown")
    GPU_MEM_USED=$(echo "$STATUS_RESPONSE" | jq -r '.gpu.memory_used_mb // "?"' 2>/dev/null || echo "?")
    GPU_MEM_TOTAL=$(echo "$STATUS_RESPONSE" | jq -r '.gpu.memory_total_mb // "?"' 2>/dev/null || echo "?")
    UPTIME_SECONDS=$(echo "$STATUS_RESPONSE" | jq -r '.uptime_seconds // 0' 2>/dev/null || echo "0")

    # Try to get model from status response
    ENV_MODEL=$(echo "$STATUS_RESPONSE" | jq -r '.environment.WHISPER_MODEL // empty' 2>/dev/null || echo "")
    if [ -n "$ENV_MODEL" ]; then
        MODEL_NAME="$ENV_MODEL"
    fi
    ENV_COMPUTE=$(echo "$STATUS_RESPONSE" | jq -r '.environment.WHISPER_COMPUTE_TYPE // empty' 2>/dev/null || echo "")
    if [ -n "$ENV_COMPUTE" ]; then
        COMPUTE_TYPE="$ENV_COMPUTE"
    fi
fi

# ============================================================================
# Output results
# ============================================================================

# Count passes
PASS_COUNT=0
TOTAL_COUNT=3
[ "$HEALTH_PASS" = true ] && PASS_COUNT=$((PASS_COUNT + 1))
[ "$READY_PASS" = true ] && PASS_COUNT=$((PASS_COUNT + 1))
[ "$STATUS_PASS" = true ] && PASS_COUNT=$((PASS_COUNT + 1))

if [ "$JSON_OUTPUT" = true ]; then
    # JSON output mode
    cat <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "instance_id": "$GPU_INSTANCE_ID",
  "instance_ip": "$GPU_IP",
  "tests": {
    "health": {"passed": $HEALTH_PASS, "status_code": $HEALTH_CODE, "response_time_ms": $HEALTH_TIME},
    "ready": {"passed": $READY_PASS, "status_code": $READY_CODE, "response_time_ms": $READY_TIME},
    "status": {"passed": $STATUS_PASS, "status_code": $STATUS_CODE, "response_time_ms": $STATUS_TIME}
  },
  "summary": {
    "passed": $PASS_COUNT,
    "failed": $((TOTAL_COUNT - PASS_COUNT)),
    "total": $TOTAL_COUNT
  },
  "gpu": {
    "name": "$GPU_NAME",
    "memory_used_mb": $GPU_MEM_USED,
    "memory_total_mb": $GPU_MEM_TOTAL
  },
  "configuration": {
    "model": "$MODEL_NAME",
    "compute_type": "$COMPUTE_TYPE"
  },
  "uptime_seconds": $UPTIME_SECONDS
}
EOF
else
    # Human-readable output
    echo ""
    echo "============================================================================"
    echo "Test Results"
    echo "============================================================================"
    echo ""

    if [ "$PASS_COUNT" -eq "$TOTAL_COUNT" ]; then
        print_status "ok" "All $TOTAL_COUNT tests passed!"
    else
        print_status "warn" "$PASS_COUNT/$TOTAL_COUNT tests passed"
    fi
    echo ""

    if [ "$STATUS_PASS" = true ]; then
        echo "System Info:"
        echo "  GPU:           $GPU_NAME"
        echo "  GPU Memory:    ${GPU_MEM_USED}MB / ${GPU_MEM_TOTAL}MB"
        echo "  Model:         $MODEL_NAME ($COMPUTE_TYPE)"
        if [ "$UPTIME_SECONDS" != "0" ]; then
            echo "  Uptime:        $(format_duration $UPTIME_SECONDS)"
        fi
        echo ""
    fi

    echo "Endpoints:"
    echo "  WebSocket:     ws://$GPU_IP:$WHISPERLIVE_PORT"
    echo "  Health:        http://$GPU_IP:$HEALTH_CHECK_PORT/health"
    echo "  Status:        http://$GPU_IP:$HEALTH_CHECK_PORT/status"
    echo ""

    if [ "$PASS_COUNT" -ne "$TOTAL_COUNT" ]; then
        echo "Troubleshooting:"
        echo "  View logs: ./scripts/870-logs.sh"
        echo "  Restart:   ./scripts/030-start-whisperlive.sh --restart"
        echo ""
    fi
fi

# Exit with appropriate code
if [ "$PASS_COUNT" -eq "$TOTAL_COUNT" ]; then
    exit 0
else
    exit 1
fi

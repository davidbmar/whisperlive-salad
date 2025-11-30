#!/usr/bin/env python3
"""
Health Check Server for Salad GPU Deployment

Provides HTTP endpoints for container health monitoring:
- GET /health - Basic health check (returns 200 OK)
- GET /ready - Readiness check (checks if WhisperLive is accepting connections)
- GET /status - Detailed status with GPU info and metrics

Runs on port 9999 (configurable via HEALTH_CHECK_PORT env var)
"""

import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

# Configuration
HEALTH_CHECK_PORT = int(os.environ.get("HEALTH_CHECK_PORT", 9999))
WHISPERLIVE_PORT = int(os.environ.get("WHISPERLIVE_PORT", 9090))
LOG_FORMAT = os.environ.get("LOG_FORMAT", "json")

# Global state
startup_time = datetime.now(timezone.utc)
whisperlive_ready = False
gpu_info = {}


def log(level: str, message: str, **extra):
    """Structured logging to stdout"""
    if LOG_FORMAT == "json":
        entry = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": level,
            "component": "healthcheck",
            "message": message,
            **extra
        }
        print(json.dumps(entry), flush=True)
    else:
        print(f"[{level}] {message}", flush=True)


def get_gpu_info() -> dict:
    """Query GPU information using nvidia-smi"""
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0:
            parts = result.stdout.strip().split(", ")
            if len(parts) >= 6:
                return {
                    "name": parts[0],
                    "memory_total_mb": int(parts[1]),
                    "memory_used_mb": int(parts[2]),
                    "memory_free_mb": int(parts[3]),
                    "temperature_c": int(parts[4]),
                    "utilization_percent": int(parts[5])
                }
    except Exception as e:
        log("WARN", f"Failed to get GPU info: {e}")
    return {}


def check_whisperlive_port() -> bool:
    """Check if WhisperLive is listening on its port"""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            result = s.connect_ex(("127.0.0.1", WHISPERLIVE_PORT))
            return result == 0
    except Exception:
        return False


class HealthCheckHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for health check endpoints"""

    def log_message(self, format, *args):
        """Override to use structured logging"""
        log("DEBUG", f"HTTP {args[0]}", method=args[0].split()[0] if args else "")

    def send_json_response(self, status: int, data: dict):
        """Send JSON response with proper headers"""
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global whisperlive_ready, gpu_info

        if self.path == "/health":
            # Basic health check - always returns OK if server is running
            self.send_json_response(200, {
                "status": "healthy",
                "timestamp": datetime.now(timezone.utc).isoformat()
            })

        elif self.path == "/ready":
            # Readiness check - verifies WhisperLive is accepting connections
            whisperlive_ready = check_whisperlive_port()
            if whisperlive_ready:
                self.send_json_response(200, {
                    "status": "ready",
                    "whisperlive_port": WHISPERLIVE_PORT,
                    "timestamp": datetime.now(timezone.utc).isoformat()
                })
            else:
                self.send_json_response(503, {
                    "status": "not_ready",
                    "reason": "WhisperLive not accepting connections",
                    "whisperlive_port": WHISPERLIVE_PORT,
                    "timestamp": datetime.now(timezone.utc).isoformat()
                })

        elif self.path == "/status":
            # Detailed status with GPU info
            gpu_info = get_gpu_info()
            uptime_seconds = (datetime.now(timezone.utc) - startup_time).total_seconds()
            whisperlive_ready = check_whisperlive_port()

            self.send_json_response(200, {
                "status": "healthy" if whisperlive_ready else "starting",
                "uptime_seconds": int(uptime_seconds),
                "startup_time": startup_time.isoformat(),
                "whisperlive": {
                    "ready": whisperlive_ready,
                    "port": WHISPERLIVE_PORT
                },
                "gpu": gpu_info,
                "environment": {
                    "WHISPER_MODEL": os.environ.get("WHISPER_MODEL", "small.en"),
                    "WHISPER_COMPUTE_TYPE": os.environ.get("WHISPER_COMPUTE_TYPE", "int8")
                },
                "timestamp": datetime.now(timezone.utc).isoformat()
            })

        else:
            self.send_json_response(404, {"error": "Not found"})


def run_server():
    """Start the health check HTTP server"""
    server = http.server.HTTPServer(("0.0.0.0", HEALTH_CHECK_PORT), HealthCheckHandler)
    log("INFO", f"Health check server starting on port {HEALTH_CHECK_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    log("INFO", "Initializing health check server", port=HEALTH_CHECK_PORT)

    # Get initial GPU info
    gpu_info = get_gpu_info()
    if gpu_info:
        log("INFO", "GPU detected", **gpu_info)
    else:
        log("WARN", "No GPU detected or nvidia-smi not available")

    # Run server
    run_server()

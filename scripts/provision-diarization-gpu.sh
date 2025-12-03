#!/bin/bash
# Provision a GPU box for diarization from S3-cached models
# Run this on a fresh GPU instance (e.g., AWS g4dn.xlarge)
#
# Prerequisites:
#   - AWS CLI configured with access to S3 bucket
#   - NVIDIA GPU with CUDA drivers installed
#   - Python 3.10+
#
# Usage: ./provision-diarization-gpu.sh [version]
# Example: ./provision-diarization-gpu.sh latest

set -e

VERSION="${1:-latest}"
S3_BUCKET="s3://dbm-cf-2-web/bintarball/diarized"
S3_PATH="${S3_BUCKET}/${VERSION}"

echo "=============================================="
echo "Provisioning Diarization GPU Box"
echo "=============================================="
echo "Version: ${VERSION}"
echo "S3 Path: ${S3_PATH}"
echo ""

# Check for GPU
if ! command -v nvidia-smi &> /dev/null; then
    echo "[WARNING] nvidia-smi not found - GPU may not be available"
else
    echo "[INFO] GPU detected:"
    nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
fi

# Check Python
PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
echo "[INFO] Python version: ${PYTHON_VERSION}"

# Step 1: System dependencies
echo ""
echo "[1/5] Installing system dependencies..."
sudo apt update
sudo apt install -y ffmpeg python3-pip

# Step 2: Download cached models
echo ""
echo "[2/5] Downloading cached models from S3..."
aws s3 cp "${S3_PATH}/huggingface-cache.tar.gz" /tmp/huggingface-cache.tar.gz

# Show manifest
echo "[INFO] Model manifest:"
aws s3 cp "${S3_PATH}/manifest.json" - 2>/dev/null | python3 -m json.tool || echo "(manifest not available)"

# Step 3: Extract models
echo ""
echo "[3/5] Extracting models to cache..."
mkdir -p ~/.cache
tar -xzf /tmp/huggingface-cache.tar.gz -C ~/.cache/
rm /tmp/huggingface-cache.tar.gz
echo "[INFO] Models installed to ~/.cache/huggingface/"

# Step 4: Install Python dependencies
echo ""
echo "[4/5] Installing Python dependencies..."
aws s3 cp "${S3_PATH}/requirements-diarization.txt" /tmp/requirements-diarization.txt
pip install -r /tmp/requirements-diarization.txt
rm /tmp/requirements-diarization.txt

# Step 5: Clone repository
echo ""
echo "[5/5] Cloning whisperlive repository..."
if [ -d ~/whisperlive ]; then
    echo "[INFO] ~/whisperlive already exists, pulling latest..."
    cd ~/whisperlive && git pull
else
    git clone https://github.com/davidbmar/whisperlive-salad.git ~/whisperlive
fi

# Verify installation
echo ""
echo "=============================================="
echo "Verifying installation..."
echo "=============================================="

python3 << 'EOF'
import sys
try:
    import torch
    print(f"[OK] PyTorch {torch.__version__}")
    print(f"[OK] CUDA available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"[OK] GPU: {torch.cuda.get_device_name(0)}")

    import pyannote.audio
    print(f"[OK] pyannote.audio {pyannote.audio.__version__}")

    # Check if models are cached
    import os
    cache_path = os.path.expanduser("~/.cache/huggingface/hub")
    models = [d for d in os.listdir(cache_path) if d.startswith("models--pyannote")]
    print(f"[OK] Cached models: {len(models)}")

    print("\n[SUCCESS] All dependencies verified!")
except Exception as e:
    print(f"[ERROR] {e}")
    sys.exit(1)
EOF

echo ""
echo "=============================================="
echo "Provisioning complete!"
echo "=============================================="
echo ""
echo "Run diarization with:"
echo "  cd ~/whisperlive"
echo "  python3 run_diarization.py -a audio.wav -t transcription.json -o output.json"
echo ""
echo "Note: No HF_TOKEN needed - models are pre-cached!"
echo "=============================================="

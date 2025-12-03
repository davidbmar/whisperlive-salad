#!/bin/bash
# Provision diarization on existing GPU instance
# Installs pyannote.audio and downloads cached models from S3
#
# Prerequisites:
#   - GPU instance already running (use 020-deploy-gpu-instance.sh)
#   - .env file configured (use 000-questions.sh)
#
# Usage: ./scripts/050-provision-diarization.sh

set -euo pipefail

SCRIPT_NAME="050-provision-diarization"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

S3_DIARIZATION_PATH="s3://dbm-cf-2-web/bintarball/diarized/latest"

echo "============================================================================"
echo "Provisioning Diarization on GPU Instance"
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

# Get current instance IP
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    print_status "error" "Could not get GPU instance IP. Is the instance running?"
    echo "Run: ./scripts/820-start-gpu-instance.sh"
    exit 1
fi

echo "GPU Instance: $GPU_INSTANCE_ID"
echo "GPU IP: $GPU_IP"
echo "S3 Models: $S3_DIARIZATION_PATH"
echo ""

# Check SSH connectivity
echo "[1/5] Checking SSH connectivity..."
if ! validate_ssh_connectivity "$GPU_IP" "$SSH_KEY_PATH"; then
    print_status "error" "Cannot SSH to GPU instance"
    exit 1
fi
print_status "ok" "SSH connection OK"
echo ""

# Check if diarization already installed
echo "[2/5] Checking existing installation..."
PYANNOTE_INSTALLED=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" \
    'pip show pyannote-audio 2>/dev/null | grep Version || echo "not installed"')

if [[ "$PYANNOTE_INSTALLED" == *"not installed"* ]]; then
    print_status "info" "pyannote.audio not installed - will install"
else
    print_status "info" "pyannote.audio already installed: $PYANNOTE_INSTALLED"
    read -p "Reinstall? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping installation. Run test with: ./scripts/055-test-diarization.sh"
        exit 0
    fi
fi
echo ""

# Install system dependencies
echo "[3/5] Installing system dependencies..."
ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" << 'REMOTE_SCRIPT'
set -e
echo "Installing ffmpeg..."
sudo apt update -qq
sudo apt install -y ffmpeg > /dev/null 2>&1
echo "ffmpeg installed: $(ffmpeg -version 2>&1 | head -1)"
REMOTE_SCRIPT
print_status "ok" "System dependencies installed"
echo ""

# Download cached models from S3
echo "[4/5] Downloading cached models from S3..."
ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" << REMOTE_SCRIPT
set -e
S3_PATH="$S3_DIARIZATION_PATH"

echo "Downloading model cache..."
aws s3 cp "\$S3_PATH/huggingface-cache.tar.gz" /tmp/huggingface-cache.tar.gz

echo "Extracting to ~/.cache..."
mkdir -p ~/.cache
tar -xzf /tmp/huggingface-cache.tar.gz -C ~/.cache/
rm /tmp/huggingface-cache.tar.gz

echo "Models installed:"
ls -la ~/.cache/huggingface/hub/ | grep models--pyannote || echo "No models found"
REMOTE_SCRIPT
print_status "ok" "Models downloaded and extracted"
echo ""

# Install Python dependencies
echo "[5/5] Installing Python dependencies..."
ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" << REMOTE_SCRIPT
set -e
S3_PATH="$S3_DIARIZATION_PATH"

echo "Downloading pinned requirements..."
aws s3 cp "\$S3_PATH/requirements-diarization.txt" /tmp/requirements-diarization.txt

echo "Installing Python packages (this may take a few minutes)..."
pip install -q -r /tmp/requirements-diarization.txt

echo ""
echo "Installed versions:"
pip show pyannote-audio 2>/dev/null | grep -E "^(Name|Version):" || echo "pyannote not found"
pip show torch 2>/dev/null | grep -E "^(Name|Version):" || echo "torch not found"
REMOTE_SCRIPT
print_status "ok" "Python dependencies installed"
echo ""

# Clone/update whisperlive repo
echo "[+] Ensuring whisperlive repo is up to date..."
ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" << 'REMOTE_SCRIPT'
set -e
if [ -d ~/whisperlive ]; then
    echo "Updating existing repo..."
    cd ~/whisperlive && git pull --quiet
else
    echo "Cloning repo..."
    git clone --quiet https://github.com/davidbmar/whisperlive-salad.git ~/whisperlive
fi
echo "Repo ready at ~/whisperlive"
REMOTE_SCRIPT
echo ""

# Verify installation
echo "============================================================================"
echo "Verifying Installation"
echo "============================================================================"
ssh -i "$SSH_KEY_PATH" ubuntu@"$GPU_IP" << 'REMOTE_SCRIPT'
python3 << 'PYTHON_VERIFY'
import sys
try:
    import torch
    print(f"[OK] PyTorch {torch.__version__}")
    print(f"[OK] CUDA available: {torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"[OK] GPU: {torch.cuda.get_device_name(0)}")

    import pyannote.audio
    print(f"[OK] pyannote.audio {pyannote.audio.__version__}")

    import os
    cache_path = os.path.expanduser("~/.cache/huggingface/hub")
    models = [d for d in os.listdir(cache_path) if d.startswith("models--pyannote")]
    print(f"[OK] Cached models: {len(models)}")

    print("\n[SUCCESS] Diarization ready!")
except Exception as e:
    print(f"[ERROR] {e}")
    sys.exit(1)
PYTHON_VERIFY
REMOTE_SCRIPT
echo ""

print_status "ok" "============================================================================"
print_status "ok" "Diarization provisioning complete!"
print_status "ok" "============================================================================"
echo ""
echo "Next steps:"
echo "  1. Test diarization: ./scripts/055-test-diarization.sh"
echo "  2. Or SSH and run manually:"
echo "     ssh -i $SSH_KEY_PATH ubuntu@$GPU_IP"
echo "     cd ~/whisperlive"
echo "     python3 run_diarization.py -a audio.wav -t transcription.json -o output.json"
echo ""

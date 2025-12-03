#!/bin/bash
# Cache diarization models to S3 for fast GPU provisioning
# Run this on a GPU box that already has the models downloaded
#
# Usage: ./cache-diarization-models.sh [version]
# Example: ./cache-diarization-models.sh 1.0

set -e

VERSION="${1:-1.0}"
S3_BUCKET="s3://dbm-cf-2-web/bintarball/diarized"
S3_PATH="${S3_BUCKET}/v${VERSION}"

echo "=============================================="
echo "Caching Diarization Models to S3"
echo "=============================================="
echo "Version: ${VERSION}"
echo "S3 Path: ${S3_PATH}"
echo ""

# Check if models exist
if [ ! -d ~/.cache/huggingface/hub ]; then
    echo "[ERROR] No HuggingFace cache found at ~/.cache/huggingface/hub"
    echo "Run diarization once first to download models."
    exit 1
fi

# Check for pyannote models
MODELS=$(ls -d ~/.cache/huggingface/hub/models--pyannote* 2>/dev/null | wc -l)
if [ "$MODELS" -eq 0 ]; then
    echo "[ERROR] No pyannote models found in cache"
    exit 1
fi
echo "[INFO] Found ${MODELS} pyannote model(s) in cache"

# Get cache size
CACHE_SIZE=$(du -sh ~/.cache/huggingface/hub | cut -f1)
echo "[INFO] Cache size: ${CACHE_SIZE}"

# Create tarball
echo ""
echo "[1/4] Creating tarball..."
tar -czf /tmp/huggingface-cache.tar.gz -C ~/.cache huggingface/
TARBALL_SIZE=$(du -sh /tmp/huggingface-cache.tar.gz | cut -f1)
echo "[INFO] Tarball size: ${TARBALL_SIZE}"

# Get package versions
echo ""
echo "[2/4] Capturing package versions..."
pip freeze | grep -iE "pyannote|torch|scipy|av|soundfile|lightning|asteroid|julius" > /tmp/requirements-diarization.txt
echo "[INFO] Captured $(wc -l < /tmp/requirements-diarization.txt) package versions"

# Create manifest
echo ""
echo "[3/4] Creating manifest..."
PYANNOTE_VERSION=$(pip show pyannote-audio | grep Version | cut -d' ' -f2)
TORCH_VERSION=$(pip show torch | grep Version | cut -d' ' -f2)
cat > /tmp/manifest.json << EOF
{
  "version": "${VERSION}",
  "created": "$(date -Iseconds)",
  "pyannote_audio": "${PYANNOTE_VERSION}",
  "torch": "${TORCH_VERSION}",
  "cuda": "$(nvcc --version 2>/dev/null | grep release | cut -d' ' -f5 | tr -d ','|| echo 'N/A')",
  "cache_size_bytes": $(stat -c%s /tmp/huggingface-cache.tar.gz),
  "models": [
    "pyannote/segmentation-3.0",
    "pyannote/wespeaker-voxceleb-resnet34-LM",
    "pyannote/speaker-diarization-3.1",
    "pyannote/speaker-diarization-community-1"
  ]
}
EOF
cat /tmp/manifest.json

# Upload to S3
echo ""
echo "[4/4] Uploading to S3..."
aws s3 cp /tmp/huggingface-cache.tar.gz "${S3_PATH}/huggingface-cache.tar.gz"
aws s3 cp /tmp/requirements-diarization.txt "${S3_PATH}/requirements-diarization.txt"
aws s3 cp /tmp/manifest.json "${S3_PATH}/manifest.json"

# Update latest pointer
echo ""
echo "[INFO] Updating 'latest' pointer..."
aws s3 sync "${S3_PATH}/" "${S3_BUCKET}/latest/"

# Cleanup
rm -f /tmp/huggingface-cache.tar.gz /tmp/requirements-diarization.txt /tmp/manifest.json

echo ""
echo "=============================================="
echo "Done! Models cached to:"
echo "  ${S3_PATH}/"
echo "  ${S3_BUCKET}/latest/"
echo ""
echo "Provision new GPU boxes with:"
echo "  ./scripts/provision-diarization-gpu.sh"
echo "=============================================="

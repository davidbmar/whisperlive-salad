#!/bin/bash
# End-to-end diarization test on GPU instance
# Downloads test files from S3 to build box, SCPs to GPU, runs diarization
#
# Prerequisites:
#   - GPU instance running with diarization provisioned (050-provision-diarization.sh)
#   - .env file configured
#   - AWS credentials on build box (for S3 access)
#
# Usage: ./scripts/055-test-diarization.sh

set -euo pipefail

SCRIPT_NAME="055-test-diarization"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"
start_logging "$SCRIPT_NAME"

S3_TEST_PATH="s3://dbm-cf-2-web/bintarball/diarized/test"
LOCAL_TEST_DIR="/tmp/diarization-test-$$"
REMOTE_TEST_DIR="/tmp/diarization-test"

# Cleanup on exit
cleanup() {
    rm -rf "$LOCAL_TEST_DIR"
}
trap cleanup EXIT

echo "============================================================================"
echo "Diarization End-to-End Test"
echo "============================================================================"
echo "Start time: $(date)"
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
    exit 1
fi

echo "GPU Instance: $GPU_INSTANCE_ID"
echo "GPU IP: $GPU_IP"
echo "Test Data: $S3_TEST_PATH"
echo ""

# Check SSH connectivity
if ! validate_ssh_connectivity "$GPU_IP" "$SSH_KEY_PATH"; then
    print_status "error" "Cannot SSH to GPU instance"
    exit 1
fi
print_status "ok" "SSH connection OK"
echo ""

SCRIPT_START=$(date +%s)

# Step 1: Download test files from S3 to build box
echo "[1/6] Downloading test files from S3 to build box..."
mkdir -p "$LOCAL_TEST_DIR"
aws s3 cp "$S3_TEST_PATH/test-audio.m4a" "$LOCAL_TEST_DIR/test-audio.m4a" --quiet
aws s3 cp "$S3_TEST_PATH/test-transcription.json" "$LOCAL_TEST_DIR/transcription.json" --quiet
print_status "ok" "Downloaded test files to build box"
echo ""

# Step 2: Create remote test script
echo "[2/6] Preparing test script..."
cat > "$LOCAL_TEST_DIR/run_test.sh" << 'TESTSCRIPT'
#!/bin/bash
set -e

TEST_DIR="/tmp/diarization-test"
cd "$TEST_DIR"

echo "=============================================="
echo "Running on GPU: $(hostname)"
echo "=============================================="
echo ""

# Convert audio to WAV
echo "[3/6] Converting audio to WAV (16kHz mono)..."
STEP_START=$(date +%s)
ffmpeg -i test-audio.m4a -ar 16000 -ac 1 test-audio.wav -y 2>/dev/null
AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 test-audio.wav)
STEP_END=$(date +%s)
echo "      Converted in $((STEP_END - STEP_START))s"
AUDIO_SECS=${AUDIO_DURATION%.*}
AUDIO_MINS=$((AUDIO_SECS / 60))
echo "      Audio duration: ${AUDIO_SECS}s (~${AUDIO_MINS} min)"
echo ""

# Run diarization
echo "[4/6] Running diarization..."
echo "      (This will take a few minutes...)"
echo ""
STEP_START=$(date +%s)
cd ~/whisperlive
python3 run_diarization.py \
    -a "$TEST_DIR/test-audio.wav" \
    -t "$TEST_DIR/transcription.json" \
    -o "$TEST_DIR/diarized.json" \
    --output_srt "$TEST_DIR/diarized.srt"
STEP_END=$(date +%s)
DIARIZATION_TIME=$((STEP_END - STEP_START))
echo ""

# Generate readable transcript
echo "[5/6] Generating readable transcript..."
cd "$TEST_DIR"
python3 - << 'PYSCRIPT'
import json

with open('diarized.json') as f:
    data = json.load(f)

segments = data['segments']
speakers = data['speakers']
timing = data.get('timing', {})

output = []
current_speaker = None
current_text = []
current_start = None

for seg in segments:
    speaker = seg.get('speaker', 'UNKNOWN')
    text = seg.get('text', '').strip()
    if speaker != current_speaker:
        if current_speaker and current_text:
            output.append({'speaker': current_speaker, 'text': ' '.join(current_text), 'start': current_start})
        current_speaker = speaker
        current_text = [text] if text else []
        current_start = seg.get('start')
    else:
        if text:
            current_text.append(text)

if current_speaker and current_text:
    output.append({'speaker': current_speaker, 'text': ' '.join(current_text), 'start': current_start})

with open('transcript_readable.txt', 'w') as f:
    f.write('=' * 70 + '\n')
    f.write('DIARIZED TRANSCRIPT\n')
    f.write('=' * 70 + '\n\n')
    f.write(f'Speakers: {", ".join(speakers)}\n')
    f.write(f'Total segments: {len(segments)}\n')
    f.write(f'Speaker turns: {len(output)}\n')
    if timing:
        f.write(f'Processing time: {timing.get("processing_seconds", "N/A")}s\n')
        f.write(f'Realtime factor: {timing.get("realtime_factor", "N/A")}x\n')
    f.write('\n' + '=' * 70 + '\n\n')
    for item in output:
        mins = int(float(item['start']) // 60)
        secs = int(float(item['start']) % 60)
        f.write(f"[{mins:02d}:{secs:02d}] {item['speaker']}:\n")
        text = item['text']
        while len(text) > 66:
            wrap_at = text[:66].rfind(' ')
            if wrap_at == -1:
                wrap_at = 66
            f.write(f"    {text[:wrap_at]}\n")
            text = text[wrap_at:].strip()
        f.write(f"    {text}\n\n")

print(f"Speakers found: {len(speakers)} ({', '.join(speakers)})")
print(f"Speaker turns: {len(output)}")
PYSCRIPT
echo ""

# Show results
echo "[6/6] Results"
echo ""
echo "=============================================="
echo "TIMING SUMMARY"
echo "=============================================="
echo "Diarization time:    ${DIARIZATION_TIME}s"
echo "Audio duration:      ${AUDIO_SECS}s (~${AUDIO_MINS} min)"
if [ "$AUDIO_SECS" -gt 0 ]; then
    REALTIME_FACTOR=$((DIARIZATION_TIME * 100 / AUDIO_SECS))
    echo "Realtime factor:     0.${REALTIME_FACTOR}x (lower is faster)"
fi
echo ""

echo "=============================================="
echo "OUTPUT FILES"
echo "=============================================="
ls -lh "$TEST_DIR"/*.json "$TEST_DIR"/*.srt "$TEST_DIR"/*.txt 2>/dev/null
echo ""

echo "=============================================="
echo "TRANSCRIPT PREVIEW (first 60 lines)"
echo "=============================================="
head -60 "$TEST_DIR/transcript_readable.txt"
echo ""
echo "... (truncated - full transcript at $TEST_DIR/transcript_readable.txt)"
TESTSCRIPT

chmod +x "$LOCAL_TEST_DIR/run_test.sh"
print_status "ok" "Test script prepared"
echo ""

# Step 3: Transfer to GPU
echo "[3/6] Transferring files to GPU instance..."
ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" "rm -rf $REMOTE_TEST_DIR && mkdir -p $REMOTE_TEST_DIR"
scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no -q \
    "$LOCAL_TEST_DIR/test-audio.m4a" \
    "$LOCAL_TEST_DIR/transcription.json" \
    "$LOCAL_TEST_DIR/run_test.sh" \
    ubuntu@"$GPU_IP":"$REMOTE_TEST_DIR/"
print_status "ok" "Files transferred to GPU"
echo ""

# Step 4-6: Run test on GPU instance
print_status "info" "Running diarization test on GPU instance..."
echo ""

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" "bash $REMOTE_TEST_DIR/run_test.sh"

SCRIPT_END=$(date +%s)
TOTAL_TIME=$((SCRIPT_END - SCRIPT_START))

echo ""
echo "============================================================================"
print_status "ok" "Test complete! Total time: ${TOTAL_TIME}s"
echo "============================================================================"
echo ""
echo "To view full results on GPU:"
echo "  ssh -i $SSH_KEY_PATH ubuntu@$GPU_IP"
echo "  cat /tmp/diarization-test/transcript_readable.txt"
echo "  cat /tmp/diarization-test/diarized.srt"
echo ""
echo "To copy results locally:"
echo "  scp -i $SSH_KEY_PATH ubuntu@$GPU_IP:/tmp/diarization-test/transcript_readable.txt ."
echo ""

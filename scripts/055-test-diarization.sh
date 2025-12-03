#!/bin/bash
# End-to-end diarization test on GPU instance
# Downloads test audio from S3, runs diarization, shows readable results
#
# Prerequisites:
#   - GPU instance running with diarization provisioned (050-provision-diarization.sh)
#   - .env file configured
#
# Usage: ./scripts/055-test-diarization.sh

set -euo pipefail

SCRIPT_NAME="055-test-diarization"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"

S3_TEST_PATH="s3://dbm-cf-2-web/bintarball/diarized/test"
TEST_DIR="/tmp/diarization-test"

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

# Run test on GPU instance
SCRIPT_START=$(date +%s)

print_status "info" "Running diarization test on GPU instance..."
echo ""

ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no ubuntu@"$GPU_IP" << 'REMOTE_TEST'
#!/bin/bash
set -e

S3_TEST_PATH="s3://dbm-cf-2-web/bintarball/diarized/test"
TEST_DIR="/tmp/diarization-test"
SCRIPT_START=$(date +%s)

echo "=============================================="
echo "Running on GPU: $(hostname)"
echo "=============================================="
echo ""

# Create test directory
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Step 1: Download test files
echo "[1/5] Downloading test files from S3..."
STEP_START=$(date +%s)
aws s3 cp "$S3_TEST_PATH/test-audio.m4a" ./test-audio.m4a --quiet
aws s3 cp "$S3_TEST_PATH/test-transcription.json" ./transcription.json --quiet
STEP_END=$(date +%s)
echo "      Downloaded in $((STEP_END - STEP_START))s"
echo ""

# Step 2: Convert audio to WAV
echo "[2/5] Converting audio to WAV (16kHz mono)..."
STEP_START=$(date +%s)
ffmpeg -i test-audio.m4a -ar 16000 -ac 1 test-audio.wav -y 2>/dev/null
AUDIO_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 test-audio.wav)
STEP_END=$(date +%s)
echo "      Converted in $((STEP_END - STEP_START))s"
AUDIO_MINS=$(echo "$AUDIO_DURATION / 60" | bc -l | xargs printf "%.1f")
echo "      Audio duration: ${AUDIO_DURATION%.*}s ($AUDIO_MINS min)"
echo ""

# Step 3: Run diarization
echo "[3/5] Running diarization..."
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

# Step 4: Generate readable transcript
echo "[4/5] Generating readable transcript..."
cd "$TEST_DIR"
python3 << 'PYTHON_SCRIPT'
import json

with open('diarized.json') as f:
    data = json.load(f)

segments = data['segments']
speakers = data['speakers']
timing = data.get('timing', {})

# Group consecutive same-speaker segments
output = []
current_speaker = None
current_text = []
current_start = None

for seg in segments:
    speaker = seg.get('speaker', 'UNKNOWN')
    text = seg.get('text', '').strip()

    if speaker != current_speaker:
        if current_speaker and current_text:
            output.append({
                'speaker': current_speaker,
                'text': ' '.join(current_text),
                'start': current_start
            })
        current_speaker = speaker
        current_text = [text] if text else []
        current_start = seg.get('start')
    else:
        if text:
            current_text.append(text)

if current_speaker and current_text:
    output.append({
        'speaker': current_speaker,
        'text': ' '.join(current_text),
        'start': current_start
    })

# Write readable transcript
with open('transcript_readable.txt', 'w') as f:
    f.write('='*70 + '\n')
    f.write('DIARIZED TRANSCRIPT\n')
    f.write('='*70 + '\n\n')
    f.write(f'Speakers: {", ".join(speakers)}\n')
    f.write(f'Total segments: {len(segments)}\n')
    f.write(f'Speaker turns: {len(output)}\n')
    if timing:
        f.write(f'Processing time: {timing.get("processing_seconds", "N/A")}s\n')
        f.write(f'Realtime factor: {timing.get("realtime_factor", "N/A")}x\n')
    f.write('\n' + '='*70 + '\n\n')

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
PYTHON_SCRIPT
echo ""

# Step 5: Show results
SCRIPT_END=$(date +%s)
TOTAL_TIME=$((SCRIPT_END - SCRIPT_START))
REALTIME_FACTOR=$(echo "scale=2; $DIARIZATION_TIME / ${AUDIO_DURATION%.*}" | bc)

echo "[5/5] Results"
echo ""
echo "=============================================="
echo "TIMING SUMMARY"
echo "=============================================="
echo "Total test time:     ${TOTAL_TIME}s"
echo "Diarization time:    ${DIARIZATION_TIME}s"
echo "Audio duration:      ${AUDIO_DURATION%.*}s ($AUDIO_MINS min)"
echo "Realtime factor:     ${REALTIME_FACTOR}x (lower is faster)"
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
echo "... (truncated - full transcript on GPU at $TEST_DIR/transcript_readable.txt)"

REMOTE_TEST

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

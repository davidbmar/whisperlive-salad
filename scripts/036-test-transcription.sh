#!/bin/bash
# =============================================================================
# Test WhisperLive Transcription with Real Audio
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   1. Downloads test audio from S3
#   2. Converts to Float32 PCM @ 16kHz mono (WhisperLive format)
#   3. Sends audio via WebSocket to WhisperLive
#   4. Displays transcription results
#
# PREREQUISITES:
#   - WhisperLive running (run 030-start-whisperlive.sh first)
#   - AWS CLI configured (for S3 access)
#   - Python 3 with websockets library
#   - ffmpeg for audio conversion
#
# Usage: ./scripts/036-test-transcription.sh [audio-file.wav]
#
# =============================================================================

set -euo pipefail

SCRIPT_NAME="036-test-transcription"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common-library.sh"
start_logging "$SCRIPT_NAME"

echo "============================================================================"
echo "WhisperLive Transcription Test"
echo "============================================================================"
echo ""

# Load environment
if ! load_env_or_fail; then
    exit 1
fi

# Get GPU IP dynamically
GPU_IP=$(get_instance_ip "$GPU_INSTANCE_ID")
if [ -z "$GPU_IP" ] || [ "$GPU_IP" = "None" ]; then
    print_status "error" "Could not get GPU instance IP"
    exit 1
fi

WHISPERLIVE_PORT="${WHISPERLIVE_PORT:-9090}"
WHISPER_MODEL="${WHISPER_MODEL:-small.en}"

print_status "ok" "Configuration loaded"
echo "  GPU IP:   $GPU_IP"
echo "  Port:     $WHISPERLIVE_PORT"
echo "  Model:    $WHISPER_MODEL"
echo ""

# ============================================================================
# Check prerequisites
# ============================================================================
echo -e "${BLUE}[1/5] Checking prerequisites...${NC}"

# Check Python websockets
if ! python3 -c "import websockets" 2>/dev/null; then
    print_status "warn" "Installing python3-websockets..."
    pip3 install websockets --quiet
fi

# Check ffmpeg
if ! command -v ffmpeg &>/dev/null; then
    print_status "error" "ffmpeg not installed. Install with: sudo apt install ffmpeg"
    exit 1
fi

# Check AWS CLI
if ! command -v aws &>/dev/null; then
    print_status "error" "AWS CLI not installed"
    exit 1
fi

print_status "ok" "Prerequisites OK"
echo ""

# ============================================================================
# Get test audio
# ============================================================================
echo -e "${BLUE}[2/5] Getting test audio...${NC}"

TEST_AUDIO="${1:-}"
TEST_DIR="/tmp/whisperlive-test-$$"
mkdir -p "$TEST_DIR"

if [ -n "$TEST_AUDIO" ] && [ -f "$TEST_AUDIO" ]; then
    print_status "ok" "Using provided audio: $TEST_AUDIO"
    cp "$TEST_AUDIO" "$TEST_DIR/input.wav"
else
    # Download from S3
    S3_TEST_AUDIO="s3://dbm-cf-2-web/integration-test/test-validation.wav"
    print_status "info" "Downloading test audio from S3..."
    echo "  Source: $S3_TEST_AUDIO"

    if aws s3 cp "$S3_TEST_AUDIO" "$TEST_DIR/input.wav" --quiet 2>/dev/null; then
        print_status "ok" "Downloaded test audio from S3"
    else
        print_status "error" "Failed to download test audio from S3"
        echo "  Make sure AWS credentials are configured"
        exit 1
    fi
fi
echo ""

# ============================================================================
# Convert audio to Float32 PCM
# ============================================================================
echo -e "${BLUE}[3/5] Converting audio to Float32 PCM @ 16kHz mono...${NC}"

ffmpeg -i "$TEST_DIR/input.wav" \
    -f f32le \
    -acodec pcm_f32le \
    -ac 1 \
    -ar 16000 \
    -y "$TEST_DIR/audio.pcm" \
    -loglevel quiet

if [ ! -f "$TEST_DIR/audio.pcm" ]; then
    print_status "error" "Failed to convert audio"
    exit 1
fi

AUDIO_SIZE=$(stat -c%s "$TEST_DIR/audio.pcm")
AUDIO_DURATION=$((AUDIO_SIZE / 64000))  # 16kHz * 4 bytes = 64000 bytes/sec
print_status "ok" "Audio converted: ${AUDIO_SIZE} bytes (~${AUDIO_DURATION}s)"
echo ""

# ============================================================================
# Send audio to WhisperLive
# ============================================================================
echo -e "${BLUE}[4/5] Sending audio to WhisperLive...${NC}"

WS_URL="ws://$GPU_IP:$WHISPERLIVE_PORT"
print_status "info" "WebSocket URL: $WS_URL"
echo ""

# Create Python test client - TRUE REAL-TIME STREAMING
# Sends audio at realistic pace while simultaneously receiving transcriptions
cat > "$TEST_DIR/test_client.py" << 'PYTHON_EOF'
#!/usr/bin/env python3
import asyncio
import websockets
import json
import sys
import time

class LiveTranscriptionTest:
    def __init__(self, ws_url, audio_file, model):
        self.ws_url = ws_url
        self.audio_file = audio_file
        self.model = model
        self.all_text = []
        self.messages = 0
        self.sending_done = False
        self.chunks_sent = 0
        self.bytes_sent = 0
        self.start_time = None

    async def send_audio(self, ws, audio_data):
        """Send audio at real-time pace (simulating live speech)"""
        # 16kHz * 4 bytes (float32) = 64000 bytes/second
        # chunk_size = 16384 bytes = ~256ms of audio
        chunk_size = 16384
        chunk_duration = chunk_size / 64000  # seconds per chunk

        self.start_time = time.time()

        for i in range(0, len(audio_data), chunk_size):
            chunk = audio_data[i:i + chunk_size]
            await ws.send(chunk)
            self.chunks_sent += 1
            self.bytes_sent += len(chunk)

            # Calculate elapsed time and how much audio we've "played"
            elapsed = time.time() - self.start_time
            audio_time = self.bytes_sent / 64000

            # Show streaming progress
            print(f"\r🎤 Streaming: {audio_time:.1f}s sent, elapsed: {elapsed:.1f}s", end="", flush=True)

            # Pace the sending to match real-time (with small buffer)
            # Send slightly faster than real-time to keep buffer full
            target_time = (self.bytes_sent / 64000) * 0.8  # 80% of real-time
            if elapsed < target_time:
                await asyncio.sleep(target_time - elapsed)

        print(f"\n📤 Finished sending: {self.chunks_sent} chunks ({self.bytes_sent} bytes)")
        self.sending_done = True

    async def receive_transcriptions(self, ws):
        """Receive and display transcriptions as they arrive"""
        print("\n" + "-" * 60)
        print("📝 LIVE TRANSCRIPTION:")
        print("-" * 60)

        last_text = ""
        timeout_count = 0
        max_timeouts = 15  # Stop after 15 consecutive timeouts (30 seconds of silence)

        while True:
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                self.messages += 1
                timeout_count = 0  # Reset timeout counter

                try:
                    data = json.loads(msg)

                    # Extract text from segments
                    if "segments" in data:
                        for seg in data["segments"]:
                            text = seg.get("text", "").strip()
                            if text and text != last_text:
                                # Show timestamp if available (convert to float)
                                start = float(seg.get("start", 0))
                                end = float(seg.get("end", 0))
                                print(f"  [{start:05.1f}s-{end:05.1f}s] {text}")
                                if text not in self.all_text:
                                    self.all_text.append(text)
                                last_text = text
                    elif "message" in data:
                        if data["message"] not in ["SERVER_READY", "DISCONNECT"]:
                            print(f"  ℹ️  {data['message']}")

                except json.JSONDecodeError:
                    pass

            except asyncio.TimeoutError:
                timeout_count += 1
                if self.sending_done and timeout_count >= max_timeouts:
                    break
                # Show waiting indicator while sending
                if not self.sending_done:
                    continue

            except websockets.exceptions.ConnectionClosed:
                print("  (connection closed)")
                break

    async def run(self):
        print(f"Connecting to {self.ws_url}...")

        try:
            async with websockets.connect(self.ws_url, ping_timeout=60) as ws:
                print("✅ WebSocket connected")

                # Send config
                config = {
                    "uid": f"live-test-{int(time.time())}",
                    "task": "transcribe",
                    "language": "en",
                    "model": self.model,
                    "use_vad": True  # Enable VAD for live streaming
                }
                await ws.send(json.dumps(config))
                print(f"📤 Config: model={self.model}, use_vad=True")

                # Wait for SERVER_READY
                try:
                    response = await asyncio.wait_for(ws.recv(), timeout=10.0)
                    data = json.loads(response)
                    if data.get("message") == "SERVER_READY":
                        print(f"✅ Server ready (backend: {data.get('backend', 'unknown')})")
                except asyncio.TimeoutError:
                    print("⚠️  No SERVER_READY (continuing)")

                # Read audio file
                with open(self.audio_file, "rb") as f:
                    audio_data = f.read()

                audio_duration = len(audio_data) / 64000
                print(f"📁 Audio loaded: {len(audio_data)} bytes ({audio_duration:.1f}s)")
                print()

                # Run sender and receiver CONCURRENTLY (true live streaming!)
                await asyncio.gather(
                    self.send_audio(ws, audio_data),
                    self.receive_transcriptions(ws)
                )

                print("-" * 60)
                print(f"\n📊 Results:")
                print(f"   Audio duration: {audio_duration:.1f}s")
                print(f"   Messages received: {self.messages}")
                print(f"   Transcription segments: {len(self.all_text)}")

                if self.all_text:
                    print(f"\n📄 FULL TRANSCRIPTION:")
                    print("=" * 60)
                    print(" ".join(self.all_text))
                    print("=" * 60)
                    return True
                else:
                    print("\n⚠️  No transcription received")
                    return False

        except Exception as e:
            print(f"❌ Error: {e}")
            import traceback
            traceback.print_exc()
            return False

if __name__ == "__main__":
    ws_url = sys.argv[1]
    audio_file = sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else "small.en"

    test = LiveTranscriptionTest(ws_url, audio_file, model)
    success = asyncio.run(test.run())
    sys.exit(0 if success else 1)
PYTHON_EOF

# Run the test
python3 "$TEST_DIR/test_client.py" "$WS_URL" "$TEST_DIR/audio.pcm" "$WHISPER_MODEL"
TEST_RESULT=$?

echo ""

# ============================================================================
# Results
# ============================================================================
echo -e "${BLUE}[5/5] Test Results${NC}"
echo ""

if [ $TEST_RESULT -eq 0 ]; then
    echo "============================================================================"
    print_status "ok" "TRANSCRIPTION TEST PASSED"
    echo "============================================================================"
else
    echo "============================================================================"
    print_status "warn" "TRANSCRIPTION TEST INCOMPLETE"
    echo "============================================================================"
    echo ""
    echo "Possible issues:"
    echo "  - Model may still be loading (try again in 30s)"
    echo "  - Audio may be too short for VAD to trigger"
    echo "  - Check logs: ./scripts/870-logs.sh"
fi

# Cleanup
rm -rf "$TEST_DIR"

echo ""
echo "To test with your own audio:"
echo "  ./scripts/036-test-transcription.sh /path/to/audio.wav"
echo ""

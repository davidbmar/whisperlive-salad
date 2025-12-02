# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WhisperLive is a real-time speech-to-text transcription application using OpenAI's Whisper model. It uses a client-server architecture with WebSocket for real-time audio streaming.

## Build & Run Commands

### Installation
```bash
bash scripts/setup.sh          # Install PyAudio dependencies
pip install -r requirements/server.txt  # Server dependencies
pip install -r requirements/client.txt  # Client dependencies
```

### Running the Server
```bash
# Default (Faster-Whisper backend)
python3 run_server.py --port 9090 --backend faster_whisper --max_clients 4

# With custom model
python3 run_server.py -p 9090 -b faster_whisper -fw "/path/to/model"

# TensorRT backend
python3 run_server.py -p 9090 -b tensorrt -trt /path/to/engine -m

# OpenVINO backend
python3 run_server.py -p 9090 -b openvino
```

### Running the Client
```bash
python3 run_client.py --server localhost --port 9090 --model small --lang en --files "audio.wav"
```

### Testing
```bash
python -m pytest tests/                    # All tests
python -m pytest tests/test_server.py      # Single test file
pytest --cov=whisper_live tests/           # With coverage
```

### Docker
```bash
docker run -it -p 9090:9090 ghcr.io/collabora/whisperlive-cpu:latest      # CPU
docker run -it --gpus all -p 9090:9090 ghcr.io/collabora/whisperlive-gpu:latest  # GPU
```

## Architecture

### Core Components

**Server (`whisper_live/server.py`)**
- `TranscriptionServer`: Main WebSocket server handling client connections
- `ClientManager`: Manages client lifecycle, timeouts, and capacity limits

**Client (`whisper_live/client.py`)**
- `Client`: Low-level WebSocket client for audio streaming
- `TranscriptionClient`: High-level interface for file/microphone transcription
- `TranscriptionTeeClient`: Multiplexes single input to multiple servers

**Backends (`whisper_live/backend/`)**
All backends extend `ServeClientBase` from `base.py`:
- `faster_whisper_backend.py`: Default CPU/GPU inference using CTranslate2
- `trt_backend.py`: NVIDIA TensorRT optimized inference
- `openvino_backend.py`: Intel OpenVINO inference
- `translation_backend.py`: Any-to-any language translation using M2M100

**Transcribers (`whisper_live/transcriber/`)**
Model-specific transcription implementations for each backend.

**VAD (`whisper_live/vad.py`)**
Voice Activity Detection using Silero VAD (ONNX) to filter silence.

### Threading Model
- Main thread: WebSocket server and client handling
- Per-client thread: Transcription processing (`speech_to_text`)
- Optional translation thread: Runs when translation is enabled
- Uses locks for thread-safe shared model access

### Message Protocol (JSON over WebSocket)

Client → Server:
```json
{"uid": "client-id", "language": "en", "task": "transcribe", "model": "small", "use_vad": true}
```

Server → Client:
```json
{"uid": "client-id", "result": [{"start": 0.0, "end": 1.5, "text": "Hello"}], "language": "en"}
```

### Audio Specifications
- Sample Rate: 16,000 Hz
- Format: Float32
- Channels: Mono

## Key Patterns

### Adding a New Backend
1. Create `whisper_live/backend/new_backend.py`
2. Extend `ServeClientBase`
3. Implement `transcribe_audio()` and `handle_transcription_output()`
4. Add `BackendType` enum entry in `server.py`
5. Add backend initialization in `TranscriptionServer.initialize_client()`

### Server Configuration
- Single model mode (default): Reuses model across clients, saves memory
- `-nsm` flag: Instantiate new model per client
- VAD filtering reduces processing overhead by ~15%

## Directory Structure

```
whisper_live/           # Main Python package
├── backend/            # Backend implementations (base, faster_whisper, trt, openvino, translation)
├── transcriber/        # Transcription implementations per backend
├── client.py           # Client implementation
├── server.py           # Server implementation
├── vad.py              # Voice Activity Detection
└── utils.py            # Utilities
docker/                 # Docker configurations (cpu, gpu, tensorrt, openvino)
salad/                  # Salad GPU Cloud deployment (see salad/README.md)
tests/                  # Unit and integration tests
scripts/                # Setup and build scripts
run_server.py           # Server entry point
run_client.py           # Client entry point
```

## Browser Extensions & iOS

- `Audio-Transcription-Chrome/`: Chrome extension
- `Audio-Transcription-Firefox/`: Firefox extension
- `Audio-Transcription-iOS/`: iOS native client

# WhisperLive Deployment Scripts

## Script Organization

### 0xx: Setup & Initial Configuration
| Script | Purpose |
|--------|---------|
| `000-questions.sh` | Interactive setup - creates `.env` config |

### 02x-03x: Deploy & Start Transcription (Stage 1)
| Script | Purpose |
|--------|---------|
| `020-deploy-gpu-instance.sh` | Create new EC2 GPU instance |
| `025-build-image.sh` | Build WhisperLive Docker image |
| `030-start-whisperlive-container.sh` | Start WhisperLive container on GPU |
| `035-test-whisperlive-health.sh` | Health check for WhisperLive |
| `036-test-transcription.sh` | Test transcription with sample audio |
| `037-push-to-registry.sh` | Push Docker image to registry |

### 05x: Diarization (Stage 2)
| Script | Purpose |
|--------|---------|
| `050-provision-diarization.sh` | Install pyannote on GPU instance (one-time) |
| `055-test-diarization.sh` | End-to-end diarization test |

### 8xx: Operations & Management
| Script | Purpose |
|--------|---------|
| `810-stop-gpu-instance.sh` | Stop GPU instance (save money) |
| `820-start-gpu-instance.sh` | Start stopped GPU instance |
| `840-stop-whisperlive.sh` | Stop WhisperLive container |
| `850-status.sh` | Check status of everything |
| `860-ssh.sh` | SSH into GPU instance |
| `870-logs.sh` | View WhisperLive container logs |

### Utility Scripts
| Script | Purpose |
|--------|---------|
| `common-library.sh` | Shared functions for all scripts |
| `cache-diarization-models.sh` | Export pyannote models to S3 |
| `provision-diarization-gpu.sh` | Standalone GPU provisioning (no .env) |
| `test-diarization.sh` | Standalone diarization test (no .env) |

---

## Full Deployment Workflow

### Fresh Deploy (First Time)

```bash
# 1. Setup configuration
./scripts/000-questions.sh

# 2. Deploy GPU instance
./scripts/020-deploy-gpu-instance.sh

# 3. Build and start transcription service
./scripts/025-build-image.sh
./scripts/030-start-whisperlive-container.sh
./scripts/035-test-whisperlive-health.sh
./scripts/036-test-transcription.sh

# 4. Add diarization capability (one-time)
./scripts/050-provision-diarization.sh

# 5. Test full pipeline
./scripts/055-test-diarization.sh
```

### Daily Operations

```bash
# Morning - start everything
./scripts/820-start-gpu-instance.sh
./scripts/030-start-whisperlive-container.sh
./scripts/850-status.sh

# Evening - stop to save costs
./scripts/840-stop-whisperlive.sh      # Stop container (optional)
./scripts/810-stop-gpu-instance.sh     # Stop instance
```

### Running Diarization

```bash
# Option 1: Use test script
./scripts/055-test-diarization.sh

# Option 2: SSH and run manually
./scripts/860-ssh.sh
cd ~/whisperlive
python3 run_diarization.py -a audio.wav -t transcription.json -o output.json
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Build Box (no GPU)                       │
│  - Runs deployment scripts                                   │
│  - Stores code in git                                        │
│  - Has AWS credentials                                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ SSH
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  GPU Instance (g4dn.xlarge)                  │
│  ┌─────────────────────┐    ┌─────────────────────────────┐ │
│  │   WhisperLive       │    │      Diarization            │ │
│  │   (Docker)          │    │      (Python/pyannote)      │ │
│  │   Port 9090         │    │                             │ │
│  │   ~3GB VRAM         │    │      ~3GB VRAM              │ │
│  └─────────────────────┘    └─────────────────────────────┘ │
│                    T4 GPU: 16GB VRAM                         │
└─────────────────────────────────────────────────────────────┘
```

**Two-Stage Pipeline:**
1. **Stage 1 (Transcription):** Audio → WhisperLive → JSON transcript
2. **Stage 2 (Diarization):** Audio + JSON → pyannote → Speaker-labeled output

---

## S3 Resources

```
s3://dbm-cf-2-web/bintarball/diarized/
├── v1.0/
│   ├── huggingface-cache.tar.gz    # Cached pyannote models (29MB)
│   ├── requirements-diarization.txt # Pinned Python versions
│   └── manifest.json               # Version metadata
├── latest/                         # Current version
└── test/
    ├── test-audio.m4a              # 48 min test audio (6 speakers)
    └── test-transcription.json     # Pre-transcribed JSON
```

---

## Cost Reference

| Instance | Hourly | Daily (24h) | Monthly |
|----------|--------|-------------|---------|
| g4dn.xlarge | $0.526 | $12.62 | $379 |
| g4dn.2xlarge | $0.752 | $18.05 | $542 |

**Tip:** Use `810-stop-gpu-instance.sh` when not in use to save costs!

---

## Performance Benchmarks

Tested on g4dn.xlarge (T4 GPU, 16GB VRAM):

| Audio Duration | Diarization Time | Realtime Factor |
|---------------|------------------|-----------------|
| 12 min | ~2 min | 0.17x |
| 48 min | ~4.3 min | 0.09x |

*Note: First run is slower (~0.4x) due to model loading. Subsequent runs benefit from warm GPU.*

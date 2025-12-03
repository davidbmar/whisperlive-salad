# Speaker Diarization Setup Guide

This documents everything needed to run offline speaker diarization on a GPU box.

## Overview

Two-stage process:
1. **Stage 1**: WhisperLive transcription → JSON output
2. **Stage 2**: Diarization → adds speaker labels to segments

## Prerequisites

### Python Dependencies
```bash
pip install pyannote.audio scipy av
```

### System Dependencies (optional - suppresses torchcodec warning)
```bash
sudo apt install ffmpeg
```

### HuggingFace Setup (ONE-TIME MANUAL STEPS)

These cannot be automated - user must do once per HuggingFace account:

1. Create account at https://huggingface.co
2. Get token from https://huggingface.co/settings/tokens
3. **Accept gated model terms** (click "Agree and access repository"):
   - https://huggingface.co/pyannote/speaker-diarization-3.1
   - https://huggingface.co/pyannote/segmentation-3.0
   - https://huggingface.co/pyannote/speaker-diarization-community-1

### Environment Variable
```bash
export HF_TOKEN=hf_your_token_here
```

## Known Issues & Fixes

### Issue 1: pyannote API change
**Error:** `Pipeline.from_pretrained() got an unexpected keyword argument 'use_auth_token'`

**Fix:** Use `token=` instead of `use_auth_token=`
```python
# Old (broken)
Pipeline.from_pretrained(model, use_auth_token=token)

# New (works)
Pipeline.from_pretrained(model, token=token)
```

### Issue 2: PyTorch 2.6+ weights_only default
**Error:** `Weights only load failed... WeightsUnpickler error: Unsupported global`

**Cause:** PyTorch 2.6 changed `torch.load()` default from `weights_only=False` to `weights_only=True`

**Fix:** Add pyannote classes to safe globals BEFORE importing pyannote:
```python
import torch
from pyannote.audio.core.task import Specifications
from pyannote.audio.core.model import Introspection

torch.serialization.add_safe_globals([
    torch.torch_version.TorchVersion,
    Specifications,
    Introspection,
])
```

**Known classes that need whitelisting:**
- `torch.torch_version.TorchVersion`
- `pyannote.audio.core.task.Specifications`
- `pyannote.audio.core.model.Introspection`
- Possibly: `pyannote.audio.core.task.Problem`, `Resolution`

### Issue 3: torchcodec warning
**Warning:** `torchcodec is not installed correctly so built-in audio decoding will fail`

**Cause:** FFmpeg libraries not found, PyTorch 2.8+ incompatibility with torchcodec

**Fix:** This is just a warning - pyannote falls back to other audio loading methods. To suppress:
```bash
sudo apt install ffmpeg libavutil-dev
```

### Issue 4: 403 error accessing gated models
**Error:** `Cannot access gated repo... Access to model is restricted`

**Fix:** User must manually accept model terms on HuggingFace website (see Prerequisites)

### Issue 5: DiarizeOutput has no itertracks
**Error:** `'DiarizeOutput' object has no attribute 'itertracks'`

**Cause:** Newer pyannote.audio versions wrap the diarization result in a DiarizeOutput object

**Fix:** Already handled in code - extracts annotation from wrapper object. If you encounter this, ensure you have the latest version of `whisper_live/diarization.py`

## Files Structure

```
whisperlive/
├── run_diarization.py      # CLI for Stage 2 (includes PyTorch fixes)
├── whisper_live/
│   ├── diarization.py      # Core diarization module
│   └── utils.py            # Includes create_srt_file_with_speakers()
```

## Usage

### Stage 1: Transcribe
```bash
python run_client.py -s localhost -p 9090 -f audio.wav --output_json transcription.json
```

### Stage 2: Diarize
```bash
export HF_TOKEN=hf_your_token
python run_diarization.py \
    -a audio.wav \
    -t transcription.json \
    -o diarized.json \
    --output_srt diarized.srt
```

### Optional arguments
- `--min_speakers N` - Hint for minimum speakers
- `--max_speakers N` - Hint for maximum speakers
- `--device cuda|cpu` - Force device selection

## Output Format

### JSON output
```json
{
  "segments": [
    {"start": "0.000", "end": "2.500", "text": "Hello", "speaker": "SPEAKER_00"},
    {"start": "2.500", "end": "5.000", "text": "Hi there", "speaker": "SPEAKER_01"}
  ],
  "speakers": ["SPEAKER_00", "SPEAKER_01"],
  "diarization": [
    {"start": 0.0, "end": 2.8, "speaker": "SPEAKER_00"},
    {"start": 2.5, "end": 5.2, "speaker": "SPEAKER_01"}
  ]
}
```

### SRT output
```
1
00:00:00,000 --> 00:00:02,500
[SPEAKER_00] Hello

2
00:00:02,500 --> 00:00:05,000
[SPEAKER_01] Hi there
```

## Setup Script (TODO)

Once working, create `scripts/setup-diarization.sh`:
```bash
#!/bin/bash
# Install dependencies
pip install pyannote.audio scipy av

# Check for HF_TOKEN
if [ -z "$HF_TOKEN" ]; then
    echo "ERROR: Set HF_TOKEN environment variable"
    echo "Get token from: https://huggingface.co/settings/tokens"
    echo ""
    echo "MANUAL STEPS REQUIRED:"
    echo "1. Accept terms at: https://huggingface.co/pyannote/speaker-diarization-3.1"
    echo "2. Accept terms at: https://huggingface.co/pyannote/segmentation-3.0"
    exit 1
fi

echo "Setup complete. Run with:"
echo "  python run_diarization.py -a audio.wav -t transcription.json -o output.json"
```

## Version Compatibility

Tested with:
- Python 3.10
- PyTorch 2.8.0+cu128
- pyannote.audio (latest as of Dec 2025)
- CUDA 12.8

## Troubleshooting

### Clear HuggingFace cache
If models seem corrupted or you get persistent errors:
```bash
rm -rf ~/.cache/huggingface/hub/models--pyannote*
rm -rf ~/.cache/torch/pyannote*
```

### Check GPU availability
```python
import torch
print(torch.cuda.is_available())
print(torch.cuda.get_device_name(0))
```

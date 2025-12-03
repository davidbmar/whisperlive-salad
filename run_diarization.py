#!/usr/bin/env python3
"""
Stage 2: Offline Speaker Diarization

Takes transcription output from WhisperLive (Stage 1) and adds speaker labels.

Usage:
    python run_diarization.py -a audio.wav -t transcription.json -o diarized.json

Example workflow:
    # Stage 1: Transcribe with WhisperLive
    python run_client.py -s localhost -p 9090 -f audio.wav --output_json transcription.json

    # Stage 2: Add speaker diarization
    python run_diarization.py -a audio.wav -t transcription.json -o diarized.json --output_srt diarized.srt
"""

# CRITICAL: Fix PyTorch 2.6+ weights_only=True breaking pyannote
# Must add all pyannote classes to safe globals before loading models
import torch

# Add all known safe globals needed by pyannote
from pyannote.audio.core.task import Specifications
from pyannote.audio.core.model import Introspection
torch.serialization.add_safe_globals([
    torch.torch_version.TorchVersion,
    Specifications,
    Introspection,
])

# Also try to add any other pyannote classes that might be needed
try:
    from pyannote.audio.core.task import Problem, Resolution, UnknownSpecificationsError
    torch.serialization.add_safe_globals([Problem, Resolution])
except ImportError:
    pass

import argparse
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(
        description="Add speaker diarization to WhisperLive transcription output.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument(
        '--audio', '-a',
        type=str,
        required=True,
        help='Path to the audio file.'
    )
    parser.add_argument(
        '--transcription', '-t',
        type=str,
        required=True,
        help='Path to transcription JSON from Stage 1 (WhisperLive output).'
    )
    parser.add_argument(
        '--output', '-o',
        type=str,
        default='output_diarized.json',
        help='Output path for diarized JSON (default: output_diarized.json).'
    )
    parser.add_argument(
        '--output_srt',
        type=str,
        default=None,
        help='Also output SRT file with speaker labels (optional).'
    )
    parser.add_argument(
        '--hf_token',
        type=str,
        default=None,
        help='HuggingFace token for pyannote. Can also use HF_TOKEN env variable.'
    )
    parser.add_argument(
        '--device',
        type=str,
        choices=['cuda', 'cpu'],
        default=None,
        help='Device to run diarization on (default: auto-detect).'
    )
    parser.add_argument(
        '--min_speakers',
        type=int,
        default=None,
        help='Minimum number of speakers (helps model if you know).'
    )
    parser.add_argument(
        '--max_speakers',
        type=int,
        default=None,
        help='Maximum number of speakers (helps model if you know).'
    )

    args = parser.parse_args()

    # Validate inputs
    audio_path = Path(args.audio)
    if not audio_path.exists():
        print(f"[ERROR] Audio file not found: {args.audio}")
        sys.exit(1)

    transcription_path = Path(args.transcription)
    if not transcription_path.exists():
        print(f"[ERROR] Transcription file not found: {args.transcription}")
        sys.exit(1)

    # Import here to avoid slow import if just showing help
    from whisper_live.diarization import OfflineDiarizer

    try:
        # Initialize diarizer
        diarizer = OfflineDiarizer(
            hf_token=args.hf_token,
            device=args.device
        )

        # Process
        result = diarizer.process(
            audio_path=str(audio_path),
            transcription_path=str(transcription_path),
            min_speakers=args.min_speakers,
            max_speakers=args.max_speakers
        )

        # Save outputs
        diarizer.save_json(result, args.output)

        if args.output_srt:
            diarizer.save_srt(result, args.output_srt)

        # Print summary
        print(f"\n[DONE] Diarization complete!")
        print(f"  Speakers found: {', '.join(result['speakers'])}")
        print(f"  Segments: {len(result['segments'])}")
        print(f"  Output: {args.output}")
        if args.output_srt:
            print(f"  SRT: {args.output_srt}")

    except ImportError as e:
        print(f"[ERROR] {e}")
        print("\nInstall pyannote.audio with:")
        print("  pip install pyannote.audio")
        sys.exit(1)
    except ValueError as e:
        print(f"[ERROR] {e}")
        sys.exit(1)
    except Exception as e:
        print(f"[ERROR] Diarization failed: {e}")
        sys.exit(1)


if __name__ == '__main__':
    main()

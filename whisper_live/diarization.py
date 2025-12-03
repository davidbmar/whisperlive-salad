"""
Offline speaker diarization module for WhisperLive.

This module provides speaker diarization as a post-processing step,
taking transcription output and audio to assign speaker labels.

Usage:
    from whisper_live.diarization import OfflineDiarizer

    diarizer = OfflineDiarizer(hf_token="your_token")
    result = diarizer.process("audio.wav", "transcription.json")
"""

import json
import os
from typing import List, Tuple, Dict, Any, Optional

import torch
import numpy as np


class OfflineDiarizer:
    """
    Offline speaker diarization using pyannote.audio.

    Processes complete audio files and aligns speaker labels
    with existing transcription segments.
    """

    def __init__(
        self,
        hf_token: Optional[str] = None,
        device: Optional[str] = None,
        model: str = "pyannote/speaker-diarization-3.1"
    ):
        """
        Initialize the diarizer.

        Args:
            hf_token: HuggingFace token for pyannote models.
                     If None, reads from HF_TOKEN environment variable.
            device: Device to run on ("cuda" or "cpu").
                   Auto-detects if None.
            model: Pyannote model identifier.
        """
        try:
            from pyannote.audio import Pipeline
        except ImportError:
            raise ImportError(
                "pyannote.audio is required for diarization. "
                "Install with: pip install pyannote.audio"
            )

        self.hf_token = hf_token or os.environ.get("HF_TOKEN")
        if not self.hf_token:
            raise ValueError(
                "HuggingFace token required. Provide via hf_token parameter "
                "or HF_TOKEN environment variable. "
                "Get your token at: https://huggingface.co/settings/tokens"
            )

        if device is None:
            self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        else:
            self.device = torch.device(device)

        print(f"[INFO] Loading diarization model on {self.device}...")
        # Note: newer pyannote versions use 'token' instead of 'use_auth_token'
        try:
            self.pipeline = Pipeline.from_pretrained(model, token=self.hf_token)
        except TypeError:
            # Fallback for older versions
            self.pipeline = Pipeline.from_pretrained(model, use_auth_token=self.hf_token)
        self.pipeline.to(self.device)
        print("[INFO] Diarization model loaded.")

    def diarize_file(
        self,
        audio_path: str,
        min_speakers: Optional[int] = None,
        max_speakers: Optional[int] = None
    ) -> List[Tuple[float, float, str]]:
        """
        Run diarization on an audio file.

        Args:
            audio_path: Path to the audio file.
            min_speakers: Minimum number of speakers (optional hint).
            max_speakers: Maximum number of speakers (optional hint).

        Returns:
            List of (start_time, end_time, speaker_label) tuples.
        """
        print(f"[INFO] Running diarization on {audio_path}...")

        # Build pipeline parameters
        params = {}
        if min_speakers is not None:
            params["min_speakers"] = min_speakers
        if max_speakers is not None:
            params["max_speakers"] = max_speakers

        # Run diarization
        if params:
            result = self.pipeline(audio_path, **params)
        else:
            result = self.pipeline(audio_path)

        # Handle different pyannote output types
        # Newer versions return DiarizeOutput, older return Annotation directly
        if hasattr(result, 'itertracks'):
            diarization = result
        elif hasattr(result, 'annotation'):
            diarization = result.annotation
        elif hasattr(result, 'diarization'):
            diarization = result.diarization
        else:
            # Try to find the annotation attribute
            for attr in dir(result):
                obj = getattr(result, attr)
                if hasattr(obj, 'itertracks'):
                    diarization = obj
                    break
            else:
                raise ValueError(f"Cannot extract diarization from result type: {type(result)}")

        # Extract speaker turns
        turns = []
        for turn, _, speaker in diarization.itertracks(yield_label=True):
            turns.append((turn.start, turn.end, speaker))

        speakers = list(set(t[2] for t in turns))
        print(f"[INFO] Diarization complete. Found {len(speakers)} speaker(s): {speakers}")

        return turns

    def assign_speakers(
        self,
        segments: List[Dict[str, Any]],
        diarization: List[Tuple[float, float, str]]
    ) -> List[Dict[str, Any]]:
        """
        Assign speaker labels to transcription segments based on time overlap.

        Args:
            segments: List of transcription segments with 'start', 'end', 'text'.
            diarization: List of (start, end, speaker) tuples from diarize_file().

        Returns:
            Segments with added 'speaker' field.
        """
        for seg in segments:
            seg_start = float(seg['start'])
            seg_end = float(seg['end'])

            # Find speaker with maximum overlap
            best_speaker = None
            best_overlap = 0.0

            for start, end, speaker in diarization:
                # Calculate overlap
                overlap_start = max(seg_start, start)
                overlap_end = min(seg_end, end)
                overlap = max(0, overlap_end - overlap_start)

                if overlap > best_overlap:
                    best_overlap = overlap
                    best_speaker = speaker

            seg['speaker'] = best_speaker if best_speaker else "UNKNOWN"

        return segments

    def load_transcription(self, transcription_path: str) -> List[Dict[str, Any]]:
        """
        Load transcription from JSON file.

        Supports both formats:
        - {"segments": [...]}
        - [...] (direct list)
        """
        with open(transcription_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

        if isinstance(data, list):
            return data
        elif isinstance(data, dict) and 'segments' in data:
            return data['segments']
        else:
            raise ValueError(
                f"Invalid transcription format. Expected list or dict with 'segments' key."
            )

    def process(
        self,
        audio_path: str,
        transcription_path: str,
        min_speakers: Optional[int] = None,
        max_speakers: Optional[int] = None
    ) -> Dict[str, Any]:
        """
        Full diarization pipeline: load transcription, diarize audio, merge results.

        Args:
            audio_path: Path to the audio file.
            transcription_path: Path to transcription JSON.
            min_speakers: Minimum number of speakers (optional).
            max_speakers: Maximum number of speakers (optional).

        Returns:
            Dict with 'segments' (with speaker labels), 'speakers' list,
            and raw 'diarization' turns.
        """
        # Load transcription
        segments = self.load_transcription(transcription_path)
        print(f"[INFO] Loaded {len(segments)} transcription segments.")

        # Run diarization
        diarization = self.diarize_file(
            audio_path,
            min_speakers=min_speakers,
            max_speakers=max_speakers
        )

        # Assign speakers to segments
        segments_with_speakers = self.assign_speakers(segments, diarization)

        # Get unique speakers
        speakers = sorted(set(seg['speaker'] for seg in segments_with_speakers))

        return {
            "segments": segments_with_speakers,
            "speakers": speakers,
            "diarization": [
                {"start": s, "end": e, "speaker": spk}
                for s, e, spk in diarization
            ]
        }

    def save_json(self, result: Dict[str, Any], output_path: str):
        """Save diarization result to JSON file."""
        with open(output_path, 'w', encoding='utf-8') as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
        print(f"[INFO] Saved diarized JSON to {output_path}")

    def save_srt(self, result: Dict[str, Any], output_path: str):
        """Save diarization result to SRT file with speaker labels."""
        from whisper_live.utils import create_srt_file_with_speakers
        create_srt_file_with_speakers(result['segments'], output_path)
        print(f"[INFO] Saved diarized SRT to {output_path}")

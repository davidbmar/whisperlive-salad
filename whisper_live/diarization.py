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

# PyTorch 2.6+ changed weights_only default to True, which breaks pyannote model loading.
# We need to patch torch.load BEFORE importing pyannote.audio.
import torch
_original_torch_load = torch.load
def _patched_torch_load(*args, **kwargs):
    # Force weights_only=False for pyannote model compatibility
    kwargs['weights_only'] = False
    return _original_torch_load(*args, **kwargs)
torch.load = _patched_torch_load

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

        if device is None:
            self.device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        else:
            self.device = torch.device(device)

        print(f"[INFO] Loading diarization model on {self.device}...")

        # Try loading from cache first (no token needed if models are cached)
        pipeline_loaded = False

        if not self.hf_token:
            print("[INFO] No HF_TOKEN provided, attempting to load from cache...")
            try:
                # Set HF_HUB_OFFLINE to force cache-only loading
                original_offline = os.environ.get("HF_HUB_OFFLINE")
                os.environ["HF_HUB_OFFLINE"] = "1"
                try:
                    self.pipeline = Pipeline.from_pretrained(model)
                    pipeline_loaded = True
                    print("[INFO] Successfully loaded model from cache (no token needed)")
                finally:
                    # Restore original env var state
                    if original_offline is None:
                        os.environ.pop("HF_HUB_OFFLINE", None)
                    else:
                        os.environ["HF_HUB_OFFLINE"] = original_offline
            except Exception as e:
                # Cache miss or other error - will need token
                print(f"[INFO] Cache-only loading failed: {e}")

        if not pipeline_loaded:
            if not self.hf_token:
                raise ValueError(
                    "HuggingFace token required (models not found in cache). "
                    "Provide via hf_token parameter or HF_TOKEN environment variable. "
                    "Get your token at: https://huggingface.co/settings/tokens"
                )
            # Load with token
            try:
                self.pipeline = Pipeline.from_pretrained(model, token=self.hf_token)
            except TypeError:
                # Fallback for older pyannote versions
                self.pipeline = Pipeline.from_pretrained(model, use_auth_token=self.hf_token)

        self.pipeline.to(self.device)
        print("[INFO] Diarization model loaded.")

    def diarize_file(
        self,
        audio_path: str,
        min_speakers: Optional[int] = None,
        max_speakers: Optional[int] = None,
        show_progress: bool = True
    ) -> List[Tuple[float, float, str]]:
        """
        Run diarization on an audio file.

        Args:
            audio_path: Path to the audio file.
            min_speakers: Minimum number of speakers (optional hint).
            max_speakers: Maximum number of speakers (optional hint).
            show_progress: Show progress updates during processing.

        Returns:
            List of (start_time, end_time, speaker_label) tuples.
        """
        import time
        import threading
        import subprocess

        # Get audio duration using ffprobe (more reliable than wave for various formats)
        audio_duration = None
        try:
            result = subprocess.run(
                ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                 '-of', 'default=noprint_wrappers=1:nokey=1', audio_path],
                capture_output=True, text=True
            )
            if result.returncode == 0:
                audio_duration = float(result.stdout.strip())
                print(f"[INFO] Audio duration: {audio_duration:.1f}s ({audio_duration/60:.1f} min)")
        except Exception as e:
            print(f"[INFO] Could not determine audio duration: {e}")

        print(f"[INFO] Running diarization on {audio_path}...")
        if audio_duration:
            est_time = audio_duration * 0.4  # Estimate ~0.4x realtime
            print(f"[INFO] Estimated processing time: {est_time:.0f}s ({est_time/60:.1f} min)")

        start_time = time.time()
        stop_progress = threading.Event()

        # Background progress printer
        def print_progress():
            while not stop_progress.wait(30):  # Print every 30 seconds
                elapsed = time.time() - start_time
                if audio_duration:
                    est_remaining = max(0, (audio_duration * 0.4) - elapsed)
                    print(f"[PROGRESS] Elapsed: {elapsed:.0f}s ({elapsed/60:.1f} min) | Est. remaining: {est_remaining:.0f}s")
                else:
                    print(f"[PROGRESS] Elapsed: {elapsed:.0f}s ({elapsed/60:.1f} min)")

        if show_progress:
            progress_thread = threading.Thread(target=print_progress, daemon=True)
            progress_thread.start()

        # Build pipeline parameters
        params = {}
        if min_speakers is not None:
            params["min_speakers"] = min_speakers
        if max_speakers is not None:
            params["max_speakers"] = max_speakers

        # Run diarization
        try:
            if params:
                result = self.pipeline(audio_path, **params)
            else:
                result = self.pipeline(audio_path)
        finally:
            stop_progress.set()

        elapsed = time.time() - start_time
        print(f"[INFO] Diarization inference complete. Elapsed: {elapsed:.1f}s ({elapsed/60:.1f} min)")

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
        import time
        total_start = time.time()

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
        print("[INFO] Assigning speakers to segments...")
        segments_with_speakers = self.assign_speakers(segments, diarization)

        # Get unique speakers
        speakers = sorted(set(seg['speaker'] for seg in segments_with_speakers))

        total_elapsed = time.time() - total_start

        # Get audio duration for stats
        try:
            import wave
            with wave.open(audio_path, 'rb') as wf:
                audio_duration = wf.getnframes() / wf.getframerate()
            realtime_factor = total_elapsed / audio_duration
        except Exception:
            audio_duration = None
            realtime_factor = None

        print(f"\n{'='*60}")
        print(f"[TIMING] Total processing time: {total_elapsed:.1f}s ({total_elapsed/60:.1f} min)")
        if audio_duration:
            print(f"[TIMING] Audio duration: {audio_duration:.1f}s ({audio_duration/60:.1f} min)")
            print(f"[TIMING] Realtime factor: {realtime_factor:.2f}x (lower is faster)")
        print(f"{'='*60}\n")

        return {
            "segments": segments_with_speakers,
            "speakers": speakers,
            "diarization": [
                {"start": s, "end": e, "speaker": spk}
                for s, e, spk in diarization
            ],
            "timing": {
                "processing_seconds": round(total_elapsed, 1),
                "audio_seconds": round(audio_duration, 1) if audio_duration else None,
                "realtime_factor": round(realtime_factor, 2) if realtime_factor else None
            }
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

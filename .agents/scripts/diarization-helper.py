#!/usr/bin/env python3
"""Run explicitly configured local audio.cpp Nemotron diarization on one recording."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import wave


SPEAKER_ID = re.compile(r"speaker_[0-7]$")


def run_command(command, timeout):
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise ValueError("Local audio processing exceeded its time budget") from error
    if result.returncode:
        raise ValueError("Local audio processing failed (exit " + str(result.returncode) + ")")


def normalize_turns(raw, duration):
    if not isinstance(raw, list):
        raise ValueError("Expected a list of audio.cpp speaker turns")
    turns = []
    for row in raw:
        if not isinstance(row, dict) or not SPEAKER_ID.fullmatch(str(row.get("speaker_id", ""))):
            raise ValueError("Invalid anonymous speaker label in audio.cpp output")
        start = row.get("start_sample")
        end = row.get("end_sample")
        confidence = row.get("confidence")
        if type(start) is not int or type(end) is not int:
            raise ValueError("Invalid speaker turn sample boundaries")
        if start < 0 or end <= start:
            raise ValueError("Invalid speaker turn sample boundaries")
        if end > (duration + 0.1) * 16000:
            raise ValueError("Invalid speaker turn sample boundaries")
        if type(confidence) not in (int, float):
            raise ValueError("Invalid speaker turn confidence")
        if not math.isfinite(confidence) or not 0 <= confidence <= 1:
            raise ValueError("Invalid speaker turn confidence")
        turns.append({"speaker_id": row["speaker_id"], "start": start / 16000,
                      "end": end / 16000, "confidence": confidence})
    return turns


def diarize(args):
    audio = args.audio.expanduser().resolve()
    model = args.model.expanduser().resolve()
    binary = Path(args.binary).expanduser().resolve() if args.binary else None
    if not audio.is_file() or not model.is_file():
        raise ValueError("Audio and model must be existing local files")
    if not binary or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("Specify an executable audio.cpp CLI with --binary or add audiocpp_cli to PATH")
    if args.output and args.output.expanduser().resolve() in (audio, model):
        raise ValueError("Output cannot replace the audio or model")
    if args.output and args.output.exists():
        raise ValueError("Output already exists; choose a new path")
    if not 1 <= args.threads <= 32:
        raise ValueError("--threads must be between 1 and 32")

    temp_root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", Path.home() / ".aidevops/.agent-workspace/tmp"))
    temp_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aidevops-diar-", dir=temp_root) as directory:
        wav = Path(directory) / "audio.wav"
        turns_file = Path(directory) / "turns.json"
        run_command(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(audio),
                     "-vn", "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)], 600)
        with wave.open(str(wav), "rb") as recording:
            if (recording.getframerate(), recording.getnchannels(), recording.getsampwidth()) != (16000, 1, 2):
                raise ValueError("Expected 16 kHz mono 16-bit WAV from ffmpeg")
            duration = recording.getnframes() / 16000
        run_command([str(binary), "--task", "diar", "--family", "nemotron_3_diar",
                     "--model", str(model), "--backend", args.backend,
                     "--threads", str(args.threads), "--audio", str(wav),
                     "--turns-out", str(turns_file)], 1800)
        turns = normalize_turns(json.loads(turns_file.read_text(encoding="utf-8")), duration)
    return {"model": "nemotron_3_diar", "runtime": "audio.cpp", "audio_duration": duration,
            "speaker_turns": turns}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("audio", type=Path, help="local recording; audio is never uploaded")
    parser.add_argument("--model", type=Path, required=True, help="existing licensed Nemotron GGUF weights")
    parser.add_argument("--binary", default=shutil.which("audiocpp_cli"),
                        help="existing audio.cpp CLI; never installed automatically")
    parser.add_argument("--backend", choices=("cpu", "metal"), default="cpu")
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--output", type=Path, help="new JSON output file; stdout if omitted")
    args = parser.parse_args()
    try:
        result = json.dumps(diarize(args), ensure_ascii=False, indent=2) + "\n"
        if args.output:
            descriptor = os.open(args.output.expanduser(), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as target:
                target.write(result)
        else:
            sys.stdout.write(result)
    except (OSError, ValueError, json.JSONDecodeError, wave.Error) as error:
        print("Diarization unavailable: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

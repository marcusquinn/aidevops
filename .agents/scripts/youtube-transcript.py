#!/usr/bin/env python3
"""Retrieve YouTube captions first, with local ASR or explicitly selected hosted API."""

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn

import argparse
import html
from http.client import HTTPSConnection
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import parse_qs, urlencode, urlparse


VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
TIMING = re.compile(
    r"(?P<start>\d{2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*"
    r"(?P<end>\d{2}:\d{2}:\d{2}[,.]\d{3})"
)


def video_id(value):
    parsed = urlparse(value)
    if parsed.scheme or parsed.netloc:
        if parsed.scheme != "https" or parsed.hostname not in (
            "youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"
        ):
            raise ValueError("Only HTTPS YouTube video URLs or video IDs are supported")
        if parsed.hostname == "youtu.be":
            value = parsed.path.strip("/")
        elif parsed.path == "/watch":
            value = parse_qs(parsed.query).get("v", [""])[0]
        elif parsed.path.startswith("/shorts/") or parsed.path.startswith("/live/"):
            value = parsed.path.split("/")[2]
        else:
            raise ValueError("Expected a YouTube watch, shorts, or live URL")
    if not VIDEO_ID.fullmatch(value):
        raise ValueError("Invalid YouTube video ID")
    return value


def seconds(stamp):
    hours, minutes, remainder = stamp.replace(",", ".").split(":")
    return int(hours) * 3600 + int(minutes) * 60 + float(remainder)


def captions(path):
    text = path.read_text(encoding="utf-8-sig")
    segments = []
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n")):
        lines = block.splitlines()
        timing_index = next((i for i, line in enumerate(lines) if TIMING.search(line)), None)
        if timing_index is None:
            continue
        timing = TIMING.search(lines[timing_index])
        raw = " ".join(lines[timing_index + 1:])
        cleaned = html.unescape(re.sub(r"<[^>]*>", "", raw)).strip()
        if cleaned:
            start = seconds(timing.group("start"))
            segments.append({"start": start, "duration": max(0, seconds(timing.group("end")) - start), "text": cleaned})
    return segments


def local_captions(url, language, temp):
    command = [
        "yt-dlp", "--no-playlist", "--skip-download", "--write-subs",
        "--write-auto-subs", "--sub-langs", language, "--sub-format", "vtt/srt",
        "-o", str(temp / "%(id)s.%(ext)s"), url,
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    for path in sorted([*temp.glob("*.vtt"), *temp.glob("*.srt")]):
        segments = captions(path)
        if segments:
            return segments
    print("No usable captions: " + result.stderr[-500:], file=sys.stderr)
    return None


def local_asr(url, temp, options):
    output = temp / "asr.json"
    download = subprocess.run(
        ["yt-dlp", "--no-playlist", "-x", "--audio-format", "wav",
         "-o", str(temp / "audio.%(ext)s"), url],
        capture_output=True, text=True, check=False,
    )
    audio = temp / "audio.wav"
    if download.returncode or not audio.is_file():
        raise ValueError("YouTube audio unavailable for local ASR (check yt-dlp and ffmpeg)")
    helper = Path(__file__).with_name("transcription-helper.sh")
    command = [str(helper), "transcribe", str(audio), "--backend", options.backend,
               "--format", "json", "--output", str(output)]
    if options.language != "all":
        command.extend(["--language", options.language])
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError("Local ASR failed (check installed yt-dlp, ffmpeg, and selected local backend)")
    data = json.loads(output.read_text(encoding="utf-8"))
    if not isinstance(data.get("segments"), list):
        raise ValueError("Local ASR backend did not return supported segments JSON")
    segments = [
        {"start": row["start"], "duration": row["end"] - row["start"], "text": row["text"]}
        for row in data["segments"]
    ]
    return segments, data.get("language")


def hosted(url, language):
    key = os.environ.get("TRANSCRIPTAPI_API_KEY")
    if not key:
        raise ValueError("Set TRANSCRIPTAPI_API_KEY using aidevops secret set before selecting --source api")
    params = {"video_url": url, "format": "json"}
    if language != "all":
        params["language"] = language
    connection = HTTPSConnection("transcriptapi.com", timeout=30)
    try:
        connection.request("GET", "/api/v2/youtube/transcript?" + urlencode(params),
                           headers={"Authorization": "Bearer " + key})
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError("TranscriptAPI request failed (HTTP " + str(response.status) + ")")
        data = json.load(response)
    finally:
        connection.close()
    segments = data.get("transcript")
    if not isinstance(segments, list) or not segments:
        raise ValueError("TranscriptAPI returned no segments")
    return segments, data.get("language")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", help="YouTube video ID or HTTPS URL")
    parser.add_argument("--source", choices=("local", "api"), default="local",
                        help="local captions then ASR (default), or explicitly billed API")
    parser.add_argument("--language", default="en", help="caption/ASR language (default: en)")
    parser.add_argument("--backend", choices=("faster-whisper", "whisper-cpp", "buzz"),
                        default="faster-whisper", help="local ASR backend if captions are absent")
    parser.add_argument("--output", type=Path, help="JSON output file; stdout if omitted")
    args = parser.parse_args()
    try:
        identifier = video_id(args.video)
        url = "https://www.youtube.com/watch?v=" + identifier
        if args.source == "api":
            segments, language = hosted(url, args.language)
            source = "transcriptapi"
        else:
            temp_root = Path(os.environ.get("AIDEVOPS_TEMP_DIR", Path.home() / ".aidevops/.agent-workspace/tmp"))
            temp_root.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix="aidevops-transcript-", dir=temp_root) as directory:
                segments = local_captions(url, args.language, Path(directory))
                language = args.language
                source = "captions"
                if not segments:
                    segments, language = local_asr(url, Path(directory), args)
                    source = "local-asr"
        if not segments:
            raise ValueError("No transcript segments available")
        payload = {"video_id": identifier, "source": source, "language": language,
                   "segments": segments}
        result = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
        if args.output:
            args.output.write_text(result, encoding="utf-8")
        else:
            sys.stdout.write(result)
    except (OSError, ValueError, TypeError, KeyError) as error:
        print("Transcript unavailable: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

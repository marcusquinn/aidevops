---
description: Buzz - offline audio/video transcription using OpenAI Whisper
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
---

# Buzz - Offline Transcription

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Local audio/video transcription with Whisper-family models; no cloud API required
- **Install**: `brew install --cask buzz` (macOS GUI), `pip install buzz-captions` (CLI), or build from source
- **Repo**: https://github.com/chidiwilliams/buzz (Python, MIT)
- **Backends**: Whisper, `faster-whisper`, `whisper.cpp`
- **When to use**: Privacy-sensitive transcription, subtitle export, offline batch work, quick GUI workflow on macOS

<!-- AI-CONTEXT-END -->

## Install

```bash
brew install --cask buzz
pip install buzz-captions
git clone https://github.com/chidiwilliams/buzz && cd buzz && pip install -e .
```

## Capabilities

- **Input**: MP3, WAV, FLAC, OGG, M4A, WMA, MP4, MKV, AVI, MOV, WebM
- **Output**: TXT, SRT, VTT, JSON
- **Languages**: 100+ via Whisper language support
- **Extras**: Speaker diarization, subtitle export, automatic audio extraction from video

Use `Buzz` when the requirement is local/private transcription. For provider comparison and cloud options, see `tools/voice/transcription.md`.

## CLI

```bash
buzz transcribe audio.mp3 --model large-v3 --language en
buzz transcribe audio.mp3 --model medium --task transcribe --output-format srt
buzz transcribe foreign-audio.mp3 --task translate --language auto
buzz transcribe audio.mp3 --model-type faster-whisper --model large-v3
```

## Model and backend choices

| Option | Best for | Trade-off |
|--------|----------|-----------|
| `tiny` / `base` | Quick drafts | Lower accuracy |
| `medium` | Default choice | Slower than small models |
| `large-v3` | Accuracy-critical transcripts | Highest VRAM and latency |
| `faster-whisper` | Faster, lower-memory runs | Different backend/runtime |
| `whisper.cpp` | CPU-first local use | Fewer ecosystem conveniences |

Approximate Whisper model sizes: `tiny` 39MB, `base` 74MB, `small` 244MB, `medium` 769MB, `large-v3` 1.5GB. Typical VRAM: 1GB, 1GB, 2GB, 5GB, 10GB respectively.

## aidevops examples

```bash
buzz transcribe meeting.mp4 --model medium --output-format txt > meeting-notes.txt
buzz transcribe video.mp4 --model large-v3 --output-format srt > subtitles.srt

for f in recordings/*.mp3; do
  buzz transcribe "$f" --model medium --output-format txt > "${f%.mp3}.txt"
done
```

## Related

- `tools/voice/transcription.md` - local vs cloud transcription options
- `tools/voice/speech-to-speech.md` - real-time speech pipeline
- `tools/video/remotion.md` - video workflows that consume transcripts

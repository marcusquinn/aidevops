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

- **Purpose**: Offline audio/video transcription using OpenAI Whisper models
- **Install**: `brew install --cask buzz` (macOS) or download from https://buzzcaptions.com
- **Repo**: https://github.com/chidiwilliams/buzz (13k+ stars, Python, MIT)
- **Models**: Whisper (tiny to large), faster-whisper, whisper.cpp

**When to use**: Local transcription without sending audio to cloud APIs. Supports 100+ languages, speaker diarization, and subtitle export (SRT/VTT).

<!-- AI-CONTEXT-END -->

## Installation

```bash
# macOS (GUI app)
brew install --cask buzz

# CLI / Python
pip install buzz-captions

# From source
git clone https://github.com/chidiwilliams/buzz
cd buzz && pip install -e .
```

## CLI Usage

```bash
# Transcribe audio file
buzz transcribe audio.mp3 --model large-v3 --language en

# Transcribe with timestamps
buzz transcribe audio.mp3 --model medium --task transcribe --output-format srt

# Translate to English
buzz transcribe foreign-audio.mp3 --task translate --language auto

# Use faster-whisper backend (faster, lower memory)
buzz transcribe audio.mp3 --model-type faster-whisper --model large-v3
```

## Supported Formats

- **Audio**: MP3, WAV, FLAC, OGG, M4A, WMA
- **Video**: MP4, MKV, AVI, MOV, WebM (extracts audio automatically)
- **Output**: TXT, SRT, VTT, JSON

## Model Selection

| Model | Size | Speed | Quality | VRAM |
|-------|------|-------|---------|------|
| tiny | 39MB | Fastest | Low | 1GB |
| base | 74MB | Fast | Fair | 1GB |
| small | 244MB | Medium | Good | 2GB |
| medium | 769MB | Slow | Great | 5GB |
| large-v3 | 1.5GB | Slowest | Best | 10GB |

**Recommendation**: Use `medium` for general use, `large-v3` for accuracy-critical work, `tiny`/`base` for quick drafts.

## Backends

- **Whisper**: Original OpenAI implementation (PyTorch)
- **faster-whisper**: CTranslate2 backend, 4x faster, lower memory
- **whisper.cpp**: C++ implementation, runs on CPU efficiently

## Integration with aidevops

```bash
# Transcribe meeting recording
buzz transcribe meeting.mp4 --model medium --output-format txt > meeting-notes.txt

# Generate subtitles for video content
buzz transcribe video.mp4 --model large-v3 --output-format srt > subtitles.srt

# Batch transcribe
for f in recordings/*.mp3; do
  buzz transcribe "$f" --model medium --output-format txt > "${f%.mp3}.txt"
done
```

## Related

- `tools/voice/speech-to-speech.md` - Real-time speech processing
- `tools/video/remotion.md` - Video generation (can use transcripts)

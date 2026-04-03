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
Local audio/video transcription with Whisper-family models; no cloud API required. Use for privacy-sensitive transcription, subtitle export, offline batch work. Input: MP3, WAV, FLAC, OGG, M4A, WMA, MP4, MKV, AVI, MOV, WebM. Output: TXT, SRT, VTT, JSON. 100+ languages. Speaker diarization supported. Repo: https://github.com/chidiwilliams/buzz (Python, MIT). Backends: Whisper, `faster-whisper`, `whisper.cpp`. For cloud options, see `tools/voice/transcription.md`.
<!-- AI-CONTEXT-END -->

## Install

```bash
brew install --cask buzz          # macOS GUI
pip install buzz-captions         # CLI
```

## CLI

```bash
buzz transcribe meeting.mp4 --model medium --output-format txt > notes.txt
buzz transcribe video.mp4 --model large-v3 --output-format srt > subtitles.srt
buzz transcribe foreign-audio.mp3 --task translate --language auto
for f in recordings/*.mp3; do buzz transcribe "$f" --model medium --output-format txt > "${f%.mp3}.txt"; done
```

## Models

| Option | Best for | Trade-off |
|--------|----------|-----------|
| `tiny` / `base` (39–74MB) | Quick drafts | Lower accuracy |
| `medium` (769MB) | Default | Slower than small |
| `large-v3` (1.5GB) | Accuracy-critical | 10GB VRAM, high latency |
| `faster-whisper` | Speed + low memory | Different runtime |
| `whisper.cpp` | CPU-first | Fewer conveniences |

## Related

- `tools/voice/transcription.md` - local vs cloud options
- `tools/voice/speech-to-speech.md` - real-time speech pipeline
- `tools/video/remotion.md` - video workflows consuming transcripts

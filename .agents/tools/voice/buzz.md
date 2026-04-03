---
description: Buzz - offline audio/video transcription using OpenAI Whisper
mode: subagent
tools:
  read: true
  bash: true
---

# Buzz - Offline Transcription

<!-- AI-CONTEXT-START -->
Local audio/video transcription with Whisper-family models; no cloud API required. Use for privacy-sensitive transcription, subtitle export, offline batch work. For provider comparison and cloud options, see `tools/voice/transcription.md`. Repo: https://github.com/chidiwilliams/buzz (Python, MIT). Backends: Whisper, `faster-whisper`, `whisper.cpp`.
<!-- AI-CONTEXT-END -->

**Install:** `brew install --cask buzz` (macOS GUI) · `pip install buzz-captions` (CLI)

**Input:** MP3, WAV, FLAC, OGG, M4A, WMA, MP4, MKV, AVI, MOV, WebM · **Output:** TXT, SRT, VTT, JSON · **Languages:** 100+ · **Extras:** speaker diarization, subtitle export, auto audio extraction from video

## CLI

```bash
buzz transcribe meeting.mp4 --model medium --output-format txt > notes.txt
buzz transcribe video.mp4 --model large-v3 --output-format srt > subtitles.srt
buzz transcribe foreign.mp3 --task translate --language auto
# Batch: for f in recordings/*.mp3; do buzz transcribe "$f" --model medium --output-format txt > "${f%.mp3}.txt"; done
```

## Models and backends

| Option | Best for | Trade-off |
|--------|----------|-----------|
| `tiny` / `base` (39–74MB) | Quick drafts | Lower accuracy |
| `medium` (769MB) | Default choice | Slower than small models |
| `large-v3` (1.5GB) | Accuracy-critical transcripts | Highest VRAM (10GB) and latency |
| `faster-whisper` | Faster, lower-memory runs | Different backend/runtime |
| `whisper.cpp` | CPU-first local use | Fewer ecosystem conveniences |

## Related

- `tools/voice/transcription.md` - local vs cloud transcription options
- `tools/voice/speech-to-speech.md` - real-time speech pipeline
- `tools/video/remotion.md` - video workflows that consume transcripts

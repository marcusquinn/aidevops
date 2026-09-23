---
description: Audio/video transcription with local and cloud models — Whisper, Buzz, AssemblyAI, Deepgram
mode: subagent
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Audio/Video Transcription

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `transcription-helper.sh [transcribe|models|configure|install|status] [options]`
- **Default model**: Whisper Large v3 Turbo (best speed/accuracy tradeoff)

```bash
transcription-helper.sh transcribe "https://youtu.be/VIDEO_ID"             # YouTube (requires yt-dlp + ffmpeg)
transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo    # native whisper: --model turbo
```

<!-- AI-CONTEXT-END -->

## Decision Matrix

| Criterion | Whisper (local) | Buzz (GUI) | AssemblyAI | Deepgram |
|-----------|----------------|------------|------------|----------|
| **Privacy** | Full (offline) | Full (offline) | Cloud | Cloud |
| **Cost** | Free | Free | $0.15-$0.45/hr | $0.0077/min |
| **Accuracy** | 9.0-9.8 | 9.0-9.8 | 9.6 | 9.5 |
| **Diarization** | No | No | Yes | Yes |
| **Streaming** | No | No | Yes | Yes |

**Decision flow**: Privacy/offline → Whisper/Buzz. Speaker diarization → AssemblyAI/Deepgram. Real-time → Deepgram. Highest accuracy → ElevenLabs Scribe v2 (9.9/10). Free → Whisper turbo.

**Input sources**: YouTube (`yt-dlp -x --audio-format wav`), URL (`curl` + `ffmpeg`), local audio (`.wav .mp3 .flac .ogg .m4a`), local video (`ffmpeg -i input -vn -acodec pcm_s16le output.wav`).

## Mac Dictation Alternatives

- [VoiceInk](https://tryvoiceink.com/) ([source](https://github.com/Beingpax/VoiceInk)) — local-first, system-wide macOS dictation with custom vocabulary and optional cloud text enhancement. Apple Silicon, macOS 14.4+. A practical choice for personal dictation and multilingual workflows; check the selected model's language and translation capabilities separately.
- [FluidVoice](https://altic.dev/fluid) ([source](https://github.com/altic-dev/FluidVoice)) — free, open-source, local-first system-wide dictation with optional on-device text polishing and selectable Whisper/Parakeet models. macOS 15+; Intel uses Whisper. Language support depends on the model; optional cloud enhancement changes the privacy boundary.

These are user-facing dictation apps, **not** backends of `transcription-helper.sh` or guaranteed replacements for timestamped YouTube transcripts. For translation, distinguish translating speech to another language from transcribing multilingual speech; confirm the selected app/model and output before relying on it. For repeatable file/URL transcription, use the helper above.

## YouTube Transcript Sources

Prefer existing captions with `yt-dlp-helper.sh transcript <url>`; if unavailable and audio is accessible, use the unified transcript helper below for local speech-to-text. `youtube-helper.sh` handles discovery/search separately. Parakeet is listed as a model option above and available in some Mac apps, but is **not** a selectable `transcription-helper.sh` backend today.

For a single timestamped JSON result, use `python3 .agents/scripts/youtube-transcript.py <video-id-or-url> --output transcript.json`. This tries caption tracks first and then local ASR; it never silently calls a paid service. Requires `yt-dlp` for captions; `ffmpeg` and `faster-whisper` for the default ASR fallback. Use `--backend whisper-cpp` or `--backend buzz` when those local backends are installed and can emit compatible segment JSON. Use `--language <code>` to select a caption/ASR language; the default is English. JSON contains `video_id`, `source`, `language`, and `segments` (`start`, `duration`, `text`). Only individual videos are accepted; enumerate playlists/channels with `youtube-helper.sh` before invoking it per video.

[TranscriptAPI](https://transcriptapi.com/) is an optional hosted alternative for transcripts plus YouTube search/channel/playlist browsing (REST and MCP). It uses a paid-credit model after the trial; verify current pricing, API contract, and desired data sharing before use. Store its key with `aidevops secret set`, never in a repo or command history. Do not assume local `yt-dlp` access has the hosted service's reliability.

Once the key is available as `TRANSCRIPTAPI_API_KEY` in the process environment, explicitly select `python3 .agents/scripts/youtube-transcript.py <video-id> --source api --output transcript.json` for a hosted transcript. API-backed search/channel/playlist operations remain available through the provider's REST/MCP documentation; they are not implemented in this helper.

For legitimate access issues, diagnose the error and respect platform terms, rate limits, and access controls. A browser profile or residential egress may be relevant only for an explicitly authorized isolation/geo need, not as an automatic block-bypass fallback; obtain approval and follow `tools/browser/auto-browse.md`, `tools/browser/anti-detect-browser.md`, and `tools/browser/proxy-integration.md`. Browser fingerprint changes do not themselves make `yt-dlp` succeed.

## Whisper (Local)

```bash
whisper audio.mp3 --model medium --language en                   # basic
whisper audio.mp3 --model medium --output_format srt             # subtitles
whisper audio.mp3 --model medium --output_format json            # word timestamps
whisper foreign.mp3 --task translate --model medium              # translate to English
```

### Models

| Model | Size | Accuracy | Notes |
|-------|------|----------|-------|
| `tiny`/`base` | 75-142MB | 6-7/10 | Draft/preview |
| `small` | 461MB | 8.5/10 | Good balance, multilingual |
| `medium` | 1.5GB | 9.0/10 | Solid general-purpose |
| `large-v3` | 2.9GB | 9.8/10 | Best quality/multilingual |
| **`turbo`** | **1.5GB** | **9.7/10** | **Large-v3 quality, 3x faster** |
| Parakeet V2 | 474MB | 9.4/10 | English-only (NVIDIA) |
| Apple Speech | Built-in | 9.0/10 | macOS 26+, on-device |

**faster-whisper** (`pip install faster-whisper`): `WhisperModel("medium", device="cpu", compute_type="int8")` → `model.transcribe("audio.mp3", language="en")` → iterate `seg.start`, `seg.text`.

**whisper.cpp** (Apple Silicon optimised): `git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp && make && ./models/download-ggml-model.sh medium` → `./build/bin/whisper-cli -m models/ggml-medium.bin -f audio.wav -otxt -osrt`

## Buzz (macOS GUI for Whisper)

Desktop Whisper wrapper — no cloud/API key. Supports MP3/WAV/FLAC/OGG/M4A/WMA audio and MP4/MKV/AVI/MOV/WebM video. Output: TXT/SRT/VTT/JSON.

```bash
brew install --cask buzz                                         # GUI: File → Open → Transcribe → Export
buzz transcribe audio.mp3 --model medium --output-format srt     # CLI
buzz transcribe foreign.mp3 --task translate --language auto
```

## AssemblyAI (Cloud — Speaker Diarization)

Best for meetings with speaker identification. `aidevops secret set ASSEMBLYAI_API_KEY`

```python
import assemblyai as aai, os
aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]
config = aai.TranscriptionConfig(speaker_labels=True, speakers_expected=3, auto_chapters=True)
transcript = aai.Transcriber().transcribe("meeting.mp3", config=config)
for u in transcript.utterances: print(f"Speaker {u.speaker}: {u.text}")
# Subtitles: transcript.export_subtitles_srt()
```

Additional config: `sentiment_analysis`, `entity_detection`, `auto_highlights`, `language_detection`, `punctuate`, `format_text`.

Models: U3 Pro $0.21/hr batch / $0.45/hr streaming (6 langs, promptable), U2 $0.15/hr (99 langs), Universal-Streaming $0.15/hr (English/6-lang), Whisper-Streaming $0.30/hr (99+ langs). [assemblyai.com/pricing](https://www.assemblyai.com/pricing) (March 2026).

## Deepgram (Cloud — Real-Time, Low Latency)

Best for live transcription and latency-sensitive apps. `aidevops secret set DEEPGRAM_API_KEY`

```python
from deepgram import DeepgramClient, PrerecordedOptions
import os
dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
opts = PrerecordedOptions(model="nova-3", language="en", punctuate=True, diarize=True, smart_format=True)
with open("audio.mp3", "rb") as f:
    resp = dg.listen.rest.v("1").transcribe_file({"buffer": f}, opts)
alt = resp.results.channels[0].alternatives[0]
print(alt.transcript)
for word in alt.words: print(f"[Speaker {word.speaker}] {word.word}")
```

Real-time: `dg.listen.asyncwebsocket.v("1")` with `LiveOptions(model="nova-3", smart_format=True)` + `LiveTranscriptionEvents.Transcript` handler; feed chunks via `conn.send(audio_chunk)`.

Models: Nova-3 $0.0077/min (36 langs), Nova-3 Medical $0.0077/min (English), Nova-3 Multilingual $0.0092/min (45+ langs), Nova-2 $0.0058/min (100+ langs). [deepgram.com/pricing](https://deepgram.com/pricing) (March 2026).

## Cloud APIs (Extended)

| Provider | Model | Accuracy | Cost | Notes |
|----------|-------|----------|------|-------|
| **Groq** | Whisper Large v3 Turbo | 9.6/10 | Free tier | OpenAI-compatible |
| **ElevenLabs** | Scribe v2 | 9.9/10 | Pay/min | Highest accuracy |
| **Mistral** | Voxtral Mini | 9.7/10 | Pay/token | Multilingual |
| **OpenAI** | Whisper API | 9.5/10 | $0.006/min | Reference impl |
| **Google** | Gemini 2.5 Pro | 9.7/10 | Pay/token | Multimodal input |
| **Soniox** | stt-async-v3 | 9.6/10 | Batch | Batch processing |

Keys: `aidevops secret set <PROVIDER>_API_KEY`. Groq uses OpenAI-compatible endpoint: `POST https://api.groq.com/openai/v1/audio/transcriptions` with `model=whisper-large-v3`.

## Language & Output

**Languages** — Whisper: 99 (`--language fr/zh/es`). AssemblyAI: 99 (`language_code="fr"` or `language_detection=True`). Deepgram Nova-3: 36; `nova-2` for 100+. **Formats**: `.txt` (all), `.srt`/`.vtt` (Whisper, Buzz, AssemblyAI), `.json` word timestamps (all).

## Related

- `./buzz.md` — Buzz GUI/CLI for offline Whisper transcription
- `./speech-to-speech.md` — Full voice pipeline (VAD + STT + LLM + TTS)
- `./voice-models.md` — TTS models for speech generation
- `../video/yt-dlp.md` — YouTube download helper
- `../../scripts/transcription-helper.sh` — CLI wrapper for all transcription workflows

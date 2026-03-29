---
description: Audio/video transcription with local and cloud models — Whisper, Buzz, AssemblyAI, Deepgram
mode: subagent
tools:
  read: true
  bash: true
---

# Audio/Video Transcription

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `transcription-helper.sh [transcribe|models|configure|install|status] [options]`
- **Default**: Whisper Large v3 Turbo (best speed/accuracy tradeoff)

```bash
transcription-helper.sh transcribe "https://youtu.be/VIDEO_ID"  # YouTube (requires yt-dlp + ffmpeg)
transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo  # native whisper: --model turbo
brew install yt-dlp ffmpeg && brew install --cask buzz && pip install openai-whisper faster-whisper assemblyai deepgram-sdk
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

**Decision flow**: Privacy/offline → Whisper/Buzz. Speaker diarization → AssemblyAI/Deepgram. Real-time → Deepgram. Highest accuracy → ElevenLabs Scribe v2 (9.9/10); best full-featured cloud → AssemblyAI U3 Pro (diarization + chapters). Free → Whisper turbo.

**Input sources**: YouTube (`yt-dlp -x --audio-format wav`), URL (`curl` + `ffmpeg`), local audio (`.wav .mp3 .flac .ogg .m4a`), local video (`ffmpeg -i input -vn -acodec pcm_s16le output.wav`).

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
| `medium` | 1.5GB | 9.0/10 | **Recommended default** |
| `large-v3` | 2.9GB | 9.8/10 | Best quality/multilingual |
| **`turbo`** | **1.5GB** | **9.7/10** | **Large-v3 quality, fast** |
| Parakeet V2 | 474MB | 9.4/10 | English-only (NVIDIA) |
| Apple Speech | Built-in | 9.0/10 | macOS 26+, on-device |

**faster-whisper** (`pip install faster-whisper`): `WhisperModel("medium", device="cpu", compute_type="int8")` → `model.transcribe("audio.mp3", language="en")` → iterate `seg.start`, `seg.text`.

**whisper.cpp** (Apple Silicon optimised): `git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp && make && ./models/download-ggml-model.sh medium` → `./build/bin/whisper-cli -m models/ggml-medium.bin -f audio.wav -otxt -osrt`

## Buzz (macOS GUI for Whisper)

Desktop Whisper wrapper. No cloud/API key. Audio: MP3/WAV/FLAC/OGG/M4A/WMA. Video: MP4/MKV/AVI/MOV/WebM. Output: TXT/SRT/VTT/JSON.

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

Config options: `sentiment_analysis`, `entity_detection`, `auto_highlights`, `language_detection`, `punctuate`, `format_text`.

Models: Universal-3 Pro $0.21/hr batch / $0.45/hr streaming (6 langs, promptable), Universal-2 $0.15/hr (99 langs), Universal-Streaming $0.15/hr (English/6-lang), Whisper-Streaming $0.30/hr (99+ langs). [assemblyai.com/pricing](https://www.assemblyai.com/pricing) (March 2026).

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

Real-time streaming: `dg.listen.asyncwebsocket.v("1")` with `LiveOptions(model="nova-3", smart_format=True)` + `LiveTranscriptionEvents.Transcript` handler; feed chunks via `conn.send(audio_chunk)`.

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

Store keys: `aidevops secret set <PROVIDER>_API_KEY`. Groq uses OpenAI-compatible endpoint: `POST https://api.groq.com/openai/v1/audio/transcriptions` with `model=whisper-large-v3`.

## Language & Output

**Languages** — Whisper: 99 (`--language fr/zh/es`). AssemblyAI: 99 (`language_code="fr"` or `language_detection=True`). Deepgram Nova-3: 36; `nova-2` for 100+. **Formats**: `.txt` (all), `.srt`/`.vtt` (Whisper, Buzz, AssemblyAI), `.json` word timestamps (all).

## Related

- `./buzz.md` — Buzz GUI/CLI for offline Whisper transcription
- `./speech-to-speech.md` — Full voice pipeline (VAD + STT + LLM + TTS)
- `./voice-models.md` — TTS models for speech generation
- `../video/yt-dlp.md` — YouTube download helper
- `../../scripts/transcription-helper.sh` — CLI wrapper for all transcription workflows

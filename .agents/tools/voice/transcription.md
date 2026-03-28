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
- **Deps**: `yt-dlp` (YouTube), `ffmpeg` (audio extraction), `faster-whisper` or `whisper.cpp` (local)

```bash
transcription-helper.sh transcribe "https://youtu.be/VIDEO_ID"  # YouTube
transcription-helper.sh transcribe recording.mp3                # Local file
transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo
brew install yt-dlp ffmpeg && brew install --cask buzz           # macOS deps
pip install openai-whisper faster-whisper assemblyai deepgram-sdk
```

<!-- AI-CONTEXT-END -->

## Decision Matrix

| Criterion | Whisper (local) | Buzz (GUI) | AssemblyAI | Deepgram |
|-----------|----------------|------------|------------|----------|
| **Privacy** | Full (offline) | Full (offline) | Cloud | Cloud |
| **Cost** | Free | Free | $0.15/hr (U2) – $0.45/hr (U3 Pro) | $0.0077/min (Nova-3) |
| **Setup** | pip + ffmpeg | brew install | API key only | API key only |
| **Accuracy** | 9.0–9.8 | 9.0–9.8 | 9.6 (U2) | 9.5 (Nova-3) |
| **Speaker diarization** | No | No | Yes | Yes |
| **Real-time streaming** | No | No | Yes (WebSocket) | Yes (WebSocket) |
| **Best for** | Private/offline, long files | macOS GUI users | Speaker ID, meetings | Real-time, low latency |

**Decision flow**: (1) Privacy/offline → Whisper or Buzz. (2) Speaker diarization → AssemblyAI or Deepgram. (3) Real-time → Deepgram. (4) Highest accuracy, cloud OK → AssemblyAI Universal-3 Pro. (5) Free, good enough → Whisper turbo locally.

**Input sources**: YouTube (`yt-dlp -x --audio-format wav`), direct URL (`curl` + `ffmpeg`), local audio (`.wav .mp3 .flac .ogg .m4a`), local video (`ffmpeg -i input -vn -acodec pcm_s16le output.wav`).

## Whisper (Local — OpenAI Original)

`faster-whisper` (CTranslate2-based) is 2–4x faster with comparable accuracy.

```bash
whisper audio.mp3 --model medium --language en
whisper audio.mp3 --model medium --output_format srt      # SRT subtitles
whisper audio.mp3 --model medium --output_format json     # word-level timestamps
whisper french-audio.mp3 --task translate --model medium  # translate to English
```

### Model Selection

| Model | Size | Speed | Accuracy | Use case |
|-------|------|-------|----------|----------|
| `tiny` | 75MB | Fastest | 6.0/10 | Draft/preview only |
| `base` | 142MB | Fast | 7.3/10 | Quick transcription |
| `small` | 461MB | Medium | 8.5/10 | Good balance, multilingual |
| `medium` | 1.5GB | Slow | 9.0/10 | Recommended default |
| `large-v3` | 2.9GB | Slowest | 9.8/10 | Best quality, best multilingual |
| **`turbo`** | **1.5GB** | **Fast** | **9.7/10** | **Large-v3 quality at medium speed** |
| NVIDIA Parakeet V2 | 474MB | Fastest | 9.4/10 | English-only |
| Apple Speech | Built-in | Fast | 9.0/10 | macOS 26+, on-device |

**Recommendation**: `medium` for most; `turbo` when speed matters; `large-v3` for accuracy-critical work.

### faster-whisper / whisper.cpp

```python
# faster-whisper (pip install faster-whisper)
from faster_whisper import WhisperModel
model = WhisperModel("medium", device="cpu", compute_type="int8")
for seg, _ in model.transcribe("audio.mp3", language="en"):
    print(f"[{seg.start:.2f}s] {seg.text}")
```

```bash
# whisper.cpp — Apple Silicon optimised (https://github.com/ggml-org/whisper.cpp)
git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp && make
./models/download-ggml-model.sh medium
./build/bin/whisper-cli -m models/ggml-medium.bin -f audio.wav -otxt -osrt
```

## Buzz (macOS GUI for Whisper)

Desktop app wrapping Whisper models. No cloud, no API key. Supports audio (MP3, WAV, FLAC, OGG, M4A, WMA), video (MP4, MKV, AVI, MOV, WebM), output (TXT, SRT, VTT, JSON).

```bash
brew install --cask buzz    # GUI — File → Open → model → Transcribe → Export
pip install buzz-captions   # CLI / Python
buzz transcribe audio.mp3 --model medium --output-format srt
buzz transcribe foreign.mp3 --task translate --language auto
buzz transcribe audio.mp3 --model-type faster-whisper --model large-v3
```

## AssemblyAI (Cloud — Speaker Diarization, High Accuracy)

Best for meeting transcription with speaker identification. `aidevops secret set ASSEMBLYAI_API_KEY`

```python
import assemblyai as aai, os
aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]

# Speaker diarization
config = aai.TranscriptionConfig(speaker_labels=True, speakers_expected=3)
transcript = aai.Transcriber().transcribe("meeting.mp3", config=config)
for utterance in transcript.utterances:
    print(f"Speaker {utterance.speaker}: {utterance.text}")

# Async webhook (production)
transcript = aai.Transcriber().submit("audio.mp3", aai.TranscriptionConfig(webhook_url="https://yourapp.com/webhook"))
print(transcript.id)  # poll later
```

Additional `TranscriptionConfig` options: `auto_chapters`, `sentiment_analysis`, `entity_detection`, `auto_highlights`, `language_detection`, `punctuate`, `format_text`.

### Pricing

| Model | Batch | Streaming | Notes |
|-------|-------|-----------|-------|
| Universal-3 Pro | $0.21/hr | $0.45/hr | Promptable, 6 languages |
| Universal-2 | $0.15/hr | — | 99 languages, general-purpose |
| Universal-Streaming | — | $0.15/hr | English-only, fastest |
| Universal-Streaming Multilingual | — | $0.15/hr | 6 languages |
| Whisper-Streaming | — | $0.30/hr | 99+ languages |

> Last verified: March 2026 — [assemblyai.com/pricing](https://www.assemblyai.com/pricing)

## Deepgram (Cloud — Real-Time, Low Latency)

Best for live transcription, call centres, and latency-sensitive applications. `aidevops secret set DEEPGRAM_API_KEY`

```python
from deepgram import DeepgramClient, PrerecordedOptions
import os

dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
opts = PrerecordedOptions(model="nova-3", language="en", punctuate=True, diarize=True, smart_format=True)
with open("audio.mp3", "rb") as f:
    resp = dg.listen.rest.v("1").transcribe_file({"buffer": f}, opts)
alt = resp.results.channels[0].alternatives[0]
print(alt.transcript)
for word in alt.words: print(f"[Speaker {word.speaker}] {word.word}")  # diarization
```

### Real-Time Streaming

```python
from deepgram import DeepgramClient, LiveTranscriptionEvents, LiveOptions
import asyncio, os

dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
conn = dg.listen.asyncwebsocket.v("1")
conn.on(LiveTranscriptionEvents.Transcript, lambda r, **kw: print(r.channel.alternatives[0].transcript) or None)
await conn.start(LiveOptions(model="nova-3", language="en-US", smart_format=True))
# feed audio chunks via conn.send(audio_chunk)
```

### Models & Pricing

| Model | Accuracy | Cost | Notes |
|-------|----------|------|-------|
| `nova-3` | 9.5/10 | $0.0077/min | General purpose, 36 languages |
| `nova-3-medical` | 9.6/10 | $0.0077/min | Clinical vocabulary, English only |
| `nova-3` (Multilingual) | 9.5/10 | $0.0092/min | 45+ languages |
| `nova-2` | 9.3/10 | $0.0058/min | Previous gen, wider language support |

> Last verified: March 2026 — [deepgram.com/pricing](https://deepgram.com/pricing)

## Cloud APIs (Extended)

| Provider | Model | Accuracy | Cost | Notes |
|----------|-------|----------|------|-------|
| **Groq** | Whisper Large v3 Turbo | 9.6/10 | Free tier | OpenAI-compatible API |
| **ElevenLabs** | Scribe v2 | 9.9/10 | Pay/min | Highest accuracy |
| **Mistral** | Voxtral Mini | 9.7/10 | Pay/token | Multilingual |
| **OpenAI** | Whisper API | 9.5/10 | $0.006/min | Reference implementation |
| **Google** | Gemini 2.5 Pro | 9.7/10 | Pay/token | Multimodal input |
| **Soniox** | stt-async-v3 | 9.6/10 | Batch | Batch processing |

Store API keys: `aidevops secret set <PROVIDER>_API_KEY`

```bash
# Groq (OpenAI-compatible)
curl https://api.groq.com/openai/v1/audio/transcriptions \
  -H "Authorization: Bearer ${GROQ_API_KEY}" \
  -F "file=@audio.wav" -F "model=whisper-large-v3" -F "response_format=verbose_json"
```

## Common Workflows

```bash
# Meeting — AssemblyAI speaker diarization
python3 -c "
import assemblyai as aai, os; aai.settings.api_key = os.environ['ASSEMBLYAI_API_KEY']
t = aai.Transcriber().transcribe('meeting.mp4', aai.TranscriptionConfig(speaker_labels=True, auto_chapters=True))
for u in t.utterances: print(f'[Speaker {u.speaker}] {u.text}')
"

# Meeting — local Whisper (private, no speaker labels)
whisper meeting.mp4 --model medium --output_format txt

# Video subtitles — local
whisper video.mp4 --model medium --output_format srt

# Video subtitles — AssemblyAI (cloud, higher accuracy)
python3 -c "
import assemblyai as aai, os; aai.settings.api_key = os.environ['ASSEMBLYAI_API_KEY']
t = aai.Transcriber().transcribe('video.mp4')
open('subtitles.srt', 'w').write(t.export_subtitles_srt())
"

# Podcast — transcribe then summarise
whisper episode.mp3 --model turbo --output_format txt
cat episode.txt | claude "Summarise: key topics, notable quotes, action items, guest names"

# Batch — local Whisper
for f in recordings/*.mp3; do whisper "$f" --model medium --output_format txt --output_dir transcripts/; done

# Batch — Deepgram (faster, parallel)
python3 -c "
import os, glob; from deepgram import DeepgramClient, PrerecordedOptions
dg = DeepgramClient(os.environ['DEEPGRAM_API_KEY'])
opts = PrerecordedOptions(model='nova-3', punctuate=True, smart_format=True)
os.makedirs('transcripts', exist_ok=True)
for p in glob.glob('recordings/*.mp3'):
    r = dg.listen.rest.v('1').transcribe_file({'buffer': open(p,'rb')}, opts)
    open(p.replace('recordings/','transcripts/').replace('.mp3','.txt'),'w').write(r.results.channels[0].alternatives[0].transcript)
"
```

## Language & Output Reference

**Languages** — Whisper: 99 (`--language fr/zh/es`; full list: https://github.com/openai/whisper#available-models-and-languages). AssemblyAI: 99 (`language_code="fr"` or `language_detection=True`). Deepgram Nova-3: 36 (`language="fr"`); `nova-2` for 100+.

**Output formats**: `.txt` (all tools), `.srt`/`.vtt` subtitles (Whisper, Buzz, AssemblyAI), `.json` word timestamps (all tools).

---

## Related

- `./buzz.md` — Buzz GUI/CLI for offline Whisper transcription
- `./speech-to-speech.md` — Full voice pipeline (VAD + STT + LLM + TTS)
- `./voice-models.md` — TTS models for speech generation
- `../video/yt-dlp.md` — YouTube download helper
- `../../scripts/transcription-helper.sh` — CLI wrapper for all transcription workflows

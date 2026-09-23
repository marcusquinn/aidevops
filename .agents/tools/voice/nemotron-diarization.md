---
description: Optional local Nemotron 3 speaker diarization with audio.cpp; anonymous turns, not identities
mode: subagent
tools:
  read: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Local Nemotron 3 Diarization

Use when the user wants **who spoke when** from audio they may process locally. Keep transcription (words), diarization (anonymous voice activity), and real-world identity verification separate. Do not upload audio or download/install a model implicitly.

## Readiness and use

1. Obtain a compatible `audiocpp_cli` supporting `nemotron_3_diar` (`--list-loaders --json`) and licensed [Nemotron 3 GGUF weights](https://huggingface.co/audio-cpp/Nemotron-3-Diarization-GGUF) separately. Verify the model's OpenMDW-1.1 terms and artifact checksum. `audio.cpp` code is Apache-2.0; its code license does **not** cover weights. Older binaries may predate this family.
2. Confirm `ffmpeg -version` runs. The wrapper prepares a temporary 16 kHz mono WAV from a local audio/video recording; it does not fetch URLs or contact a hosted API.
3. Request turns explicitly:

```bash
python3 .agents/scripts/diarization-helper.py recording.m4a \
  --binary /path/to/audiocpp_cli \
  --model /path/to/nemotron-3-diarization-bf16.gguf \
  --backend cpu --output speaker-turns.json
```

The output records `audio_duration` and `speaker_turns` with anonymous `speaker_0`–`speaker_7`, `start`/`end` seconds, and the model's activity `confidence`. Turns can overlap; do not force a single speaker when two channels are active. Silence can yield an empty list. The helper refuses to overwrite an existing output and writes a new output file with private permissions.

## Evidence and platform boundaries

- Pair turns with an ASR transcript on the **same audio/time base**. Plain segment-level Whisper JSON can contain two speakers in one segment; do not attach a single label to every whole segment by midpoint. Use word-level timestamps or manual boundary checks when attribution matters.
- Anonymous channel IDs remain stable only within the processed recording. Confirm affiliations using publisher metadata or on-screen labels; the model cannot name an individual. Mark uncertain/overlapping turns explicitly.
- A bounded Apple Silicon **CPU** run on a public 270-second sample completed locally in roughly 110 seconds; this is one test, not a performance promise. Metal support for this model was not verified on that Mac because the Metal compiler was unavailable. NVIDIA's NeMo route targets supported Linux NVIDIA GPUs; `audio.cpp` is a separate C++ port. The hosted Hugging Face demo may relay audio off-device and is **not** this local route.
- [NVIDIA's model explanation](https://huggingface.co/blog/nvidia/nemotron-diarization) reports up to eight speakers and initial benchmark results; evaluate speaker confusion, missed speech, and overlap on representative inputs before consequential use. Do not equate the OpenCode Zen Nemotron language models with the separate diarization model.

See `tools/voice/transcription.md` for caption-first YouTube/ASR acquisition and `content/youtube-research.md` for evidence-led speaker attribution.

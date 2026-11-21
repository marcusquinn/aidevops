---
description: Self-hosted VoiceStudio TTS, transcription and voice cloning for any project, via helper or MCP
mode: subagent
tools:
  read: true
  bash: true
  voicestudio_*: true
mcp:
  - voicestudio
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoiceStudio Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Service**: a self-hosted [VoiceStudio](https://github.com/debpalash/VoiceStudio) server (Docker, GPU) with OpenAI-compatible `/v1/audio/speech` and `/v1/audio/transcriptions`, saved voice profiles, and an MCP endpoint at `/mcp`.
- **Helper**: `voicestudio-helper.sh status|voices|speak|transcribe|clone|mcp`. Python 3 standard library only; ffmpeg only for non-WAV output of long text.
- **Server**: `VOICESTUDIO_URL` (default `http://127.0.0.1:3900`).
- **Key**: `aidevops secret set OMNIVOICE_API_KEY` once (or name another secret in `VOICESTUDIO_SECRET`). The helper injects it; never pass it on the command line.
- **MCP**: `voicestudio`, disabled globally, activated by this agent. The proxy writes generated speech to a file and returns `audio_path`, so no base64 audio enters the context.

<!-- AI-CONTEXT-END -->

## Scripts and batch work

```bash
voicestudio-helper.sh status                       # health, auth, active engine and GPU
voicestudio-helper.sh voices                       # saved profile ids for --voice
voicestudio-helper.sh speak --file chapter.txt --out chapter.mp3 --language en --voice <profile-id>
echo "Hello" | voicestudio-helper.sh speak --out hello.wav
voicestudio-helper.sh transcribe take.wav --format srt --out take.srt
voicestudio-helper.sh clone --name "Narrator" --ref ref.wav --ref-text "Transcript of ref.wav"
```

`speak` splits text at paragraphs, sentences, then clauses (220 characters by
default, `--max-chars`), because VoiceStudio abandons requests after about 300 s
of GPU time. Pieces are joined with short pauses (longer between paragraphs).
HTTP 5xx answers, including CUDA out-of-memory when the GPU is shared, are
retried with growing delays (`--retries`, `VOICESTUDIO_RETRY_DELAY`).

Any OpenAI SDK also works directly: base URL `$VOICESTUDIO_URL/v1`, model
`tts-1` (the active engine), voice = a profile id or `default`. OpenAI voice
names (`alloy`, `nova`, ...) all map to the engine's default voice.

## Agent use (MCP)

Connect `voicestudio`, inspect the tool schemas, then:

- `generate_speech`: pass `output_path` (absolute, or relative to the MCP process directory). Without it the WAV goes to `VOICESTUDIO_OUTPUT_DIR`, else `~/.aidevops/.agent-workspace/tmp/voicestudio/`.
- `transcribe`: pass `audio_file` (local path); the proxy uploads it.
- `clone_voice`: pass `ref_audio_file` (5-30 s of one clean speaker).
- `list_voices`, `list_languages`, `check_health` need no files.

For anything longer than a few sentences, run `voicestudio-helper.sh speak`
from Bash instead of `generate_speech`.

## Boundaries

- Synthesis is sequential on one GPU. Batch jobs from several projects queue
  behind each other and behind other GPU users; long jobs belong in the
  background.
- Clone only voices the user supplied or approved for this use. Record the
  source and licence in the profile name or the project's credits.
- Keep the server on loopback or a private network. If it must be reachable
  from elsewhere, put it behind an authenticating tunnel; the bearer key is
  the only protection on the API.

## Related

- `tools/voice/local-tts-models.md` - in-process local TTS models (Kokoro, F5-TTS, ...)
- `tools/voice/cloud-tts-apis.md` - hosted TTS APIs
- `tools/voice/transcription.md` - other transcription options

---
name: audio
description: Audio production pipeline - voice, sound design, emotional cues, mixing
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Audio Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Pipeline**: Voice cleanup → Voice transformation → Sound design → Mixing
- **Key Rule**: ALWAYS clean AI voice output with CapCut BEFORE ElevenLabs transformation
- **Pipeline Helper**: `voice-pipeline-helper.sh [pipeline|extract|cleanup|transform|normalize|tts|voices|clone|status]`
- **Voice Bridge**: `voice-helper.sh [talk|devices|voices|benchmark]`
- **References**: `tools/voice/speech-to-speech.md`, `voice-helper.sh`

<!-- AI-CONTEXT-END -->

## Voice Production Pipeline

**NEVER feed raw AI video audio directly to ElevenLabs** — it amplifies artifacts. Always clean first:

| Step | Tool | Purpose |
|------|------|---------|
| 1 | CapCut AI Voice Cleanup | Normalize accents/artifacts, remove robotic patterns, clean noise, standardize volume |
| 2 | ElevenLabs Transformation | Voice cloning, emotional delivery, character consistency |

**Alternative**: MiniMax TTS — talking-head content where ElevenLabs is overkill. $5/month for 120 min; 10-second clip for voice clone. See `tools/voice/voice-models.md`.

### Voice Cloning

**NEVER use pre-made ElevenLabs voices for realistic content** — widely recognised, signals "AI-generated".

| Method | Input | Use |
|--------|-------|-----|
| Voice Design | Natural language description | e.g., "warm female voice, mid-30s, slight British accent" |
| Instant Clone | 10-30 second clean clip | Quick personas |
| Professional Clone | 3-5 minutes | AI influencer personas (highest fidelity) |

**Source quality**: Single speaker, quiet environment, clear pronunciation. Cloning from existing content → run CapCut cleanup first.

**Voice consistency**: Same voice model across all channel content. Consistent pace, emotional tone, and brand term pronunciation. Update voice samples quarterly.

### Emotional Block Cues

Emotion tags for TTS engines with emotion support (ElevenLabs, ChatTTS):

```text
[neutral]Welcome to the channel.[/neutral] [excited]Today we're covering something amazing![/excited] [serious]But first, let's understand the problem.[/serious]
```

| Tag | Use Case | Pacing Position |
|-----|----------|-----------------|
| `[excited]` | Hooks, reveals, wins | Hook (0-3s), CTA (final 5s) |
| `[curious]` | Questions, exploration | Hook (0-3s) |
| `[serious]` | Problems, warnings, data | Problem (3-10s) |
| `[empathetic]` | Pain points, struggles | Problem (3-10s) |
| `[confident]` | Authority, expertise | Solution (10s+) |
| `[urgent]` | CTAs, time-sensitive | CTA (final 5s) |
| `[neutral]` | Default, informational | Any |

Scripts from `content/production-writing.md` should include emotional block markup.

## 4-Layer Audio Design

| Layer | Target LUFS | Processing / Notes |
|-------|-------------|-------------------|
| **1: Dialogue** (primary) | -15 | `Raw Voice → Noise Reduction → EQ → Compression → De-esser → Limiter`. Centered. EQ: high-pass 80Hz, presence boost 3-5kHz. Tools: CapCut, ElevenLabs, Audacity/Audition, `voice-helper.sh` |
| **2: Ambient** | -25 | Stereo width for immersion; low-pass to avoid competing with dialogue. Sources: Freesound.org (CC0), Epidemic Sound, AudioCraft, Stable Audio |
| **3: SFX** | -10 to -20 | Categories: Whooshes, Impacts, UI Sounds, Foley, Risers/Drops. Land 1-2 frames BEFORE visual event. Layer for bigger impacts; reverb to match dialogue space |
| **4: Music** | -18 to -20 | Ducking: sidechain dialogue → music. Threshold -20dB, ratio 4:1, attack 10ms, release 200ms. Sources: Epidemic Sound, Artlist, Uppbeat, Suno, Udio |

| Content Type | Ambient | Music Style | Ducking |
|--------------|---------|-------------|---------|
| UGC/Vlog | Diegetic only (room tone) | None | N/A |
| Tutorial | Minimal/none | Minimal, ambient | -6dB |
| Commercial | Designed ambience | Mixed diegetic + score | -8dB |
| Documentary | Rich environmental | Cinematic score | -4dB |
| YouTube | — | Upbeat, royalty-free | -6dB |

## LUFS Reference

| Platform | Target LUFS | Notes |
|----------|-------------|-------|
| YouTube | -14 to -16 | Normalizes to -14 |
| Podcast | -16 to -19 | Spotify normalizes to -14 |
| TikTok/Shorts | -10 to -12 | Louder for mobile |
| Broadcast TV | -23 to -24 | EBU R128 |
| Streaming (Netflix) | -27 | Wide dynamic range |
| Audiobook | -18 to -23 | Consistent, comfortable |

```bash
ffmpeg -i input.mp4 -af loudnorm=print_format=json -f null -
# Audacity: Analyze > Loudness Normalization (preview mode)
# DaVinci Resolve: Fairlight > Loudness Meter
```

**Normalization workflow**: Mix layers → measure integrated LUFS → apply normalization → limiter (true peak -1dB).

## Voice Tools

| Service | CLI | Notes |
|---------|-----|-------|
| `voice-helper.sh` | `talk [stt] [tts] [voice] [model]`, `devices`, `voices`, `benchmark` | Mic→VAD→Whisper MLX→LLM→Edge TTS; defaults: `whisper-mlx` + `edge-tts`; ~6-8s round-trip |
| ElevenLabs | `voice-pipeline-helper.sh [transform\|tts\|voices\|clone]` | Voice cloning (3-5 min sample), 29 languages, emotional control |
| Local ffmpeg | `voice-pipeline-helper.sh cleanup <audio> [output] [target-lufs]` | Noise reduction, high-pass, de-essing, loudness normalization |
| Edge TTS (free) | Used by `voice-helper.sh` | 400+ voices, 100+ languages, no API key |

## See Also

- `tools/voice/speech-to-speech.md` — Advanced voice pipeline (VAD, STT, LLM, TTS)
- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/voice-ai-models.md` — Complete model comparison (TTS, STT, S2S)
- `tools/voice/voice-models.md` — TTS model comparison (ElevenLabs, MiniMax, Qwen3-TTS)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `content/production-writing.md` — Script structure, dialogue pacing, emotional cues
- `content/production-video.md` — Video production and audio sync
- `content/optimization.md` — A/B testing audio variants

# Longform Talking-Head Pipeline (30s+)

Audio-driven pipeline: voice audio controls lip movement and timing.

`Image (1) → Script (2) → Voice (3) → Video (4) → Post-Processing (5)`

## 1. Starting Image
Use Nanobanana Pro with JSON prompts (see `content/production-image.md`). JSON `color`/`lighting` fields prevent flat output. Video models amplify artifacts — use high-res, photorealistic sources.

- **Character/Person**: Nanobanana Pro / Freepik
- **4K Refinement**: Seedream 4
- **Consistency**: Ideogram face swap

## 2. Script
Write for natural speech:
- **Contractions**: "it's", "don't", "we're" (never "it is", "do not")
- **Pacing**: 8-12 words per sentence
- **Cues**: `[excited]Text[/excited]`
- **Test**: Read aloud; if it sounds awkward, rewrite.

## 3. Voice Audio (Critical)
Robotic audio is scrolled past. **NEVER use pre-made ElevenLabs voices.** Use Voice Design or Instant Voice Clone.

| Tool | Quality | Cost | Best For |
|------|---------|------|----------|
| **ElevenLabs** | Highest | $5-99/mo | Realism, custom clones (10-30s) |
| **MiniMax TTS** | High | $5/mo | Value, easy setup (10s clone) |
| **Qwen3-TTS** | High | Free | Local/CUDA, open source (3s clone) |

*Cloning: Quiet room, no music. Cleanup via CapCut (see `content/production-audio.md`). Qwen3: `tools/voice/qwen3-tts.md`.*

## 4. Talking-Head Video
| Model | Quality | Cost | Best For |
|-------|---------|------|----------|
| **HeyGen 4** | High | Sub | All-around (see `content/heygen-skill.md`) |
| **VEED Fabric** | Highest | $$$ | Premium (see `content/video-muapi.md`) |
| **InfiniteTalk** | Good | Free | Budget/Self-hosted |

## 5. Post-Processing
1. **Upscale**: `real-video-enhancer-helper.sh upscale in.mp4 out.mp4 --scale 2`
2. **Denoise**: `real-video-enhancer-helper.sh denoise in.mp4 out.mp4`
3. **Grain**: Subtle film grain for organic look.
4. **Mix**: Layer ambient sound/music (see `content/production-audio.md`).

## Longform Assembly (30s+)
Split script into segments (e.g., 10s for HeyGen). Generate with identical settings.
```bash
printf "file '%s'\n" segment_*.mp4 > concat.txt
ffmpeg -f concat -safe 0 -i concat.txt -c copy output.mp4
# Add B-roll cuts between segments; replace audio with full-length track.
```

## Use Case Routing
| Use Case | Image | Voice | Video | Post |
|----------|-------|-------|-------|------|
| **Paid ads** | Nanobanana | ElevenLabs | VEED | Full |
| **Organic** | Freepik | MiniMax | HeyGen | Denoise |
| **Influencer** | Nanobanana | ElevenLabs | HeyGen | Grain+Upscale |
| **Budget** | Freepik | Qwen3-TTS | InfiniteTalk | Minimal |

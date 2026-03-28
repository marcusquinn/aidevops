---
description: WaveSpeed AI - unified API for 200+ generative AI models
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: false
---

# WaveSpeed AI

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Unified API gateway for 200+ generative AI models (image, video, audio, 3D, LLM)
- **API**: `https://api.wavespeed.ai/api/v3` — Bearer token via `WAVESPEED_API_KEY`
- **CLI**: `wavespeed-helper.sh [generate|status|models|upload|balance|usage]`
- **MCP**: Optional — `pip install wavespeed-mcp` for Claude Desktop integration
- **SDKs**: Python (`pip install wavespeed`), JS (`npm install wavespeed`) — not used by helper

**When to use**: Image (Flux, DALL-E, Imagen, Recraft), video (Wan, Kling, Sora, Veo, Minimax), audio (TTS, music, voice cloning), 3D (Hunyuan3D, Meshy6), utilities (upscale, face swap, OCR, try-on).

<!-- AI-CONTEXT-END -->

## Setup

```bash
# 1. Get API key at https://wavespeed.ai/accesskey
# 2. Store credentials
aidevops secret set WAVESPEED_API_KEY
# Or plaintext fallback:
echo 'export WAVESPEED_API_KEY="wsk_..."' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
# 3. Test
wavespeed-helper.sh balance
```

## API Reference

All requests: `Authorization: Bearer $WAVESPEED_API_KEY`. Model ID format: `provider/model-name`.

| Endpoint | Method | Path |
|----------|--------|------|
| Submit (async) | POST | `/predictions/{model_id}` |
| Submit (sync) | POST | `/predictions/{model_id}` + `"enable_sync_mode": true` |
| Poll status | GET | `/predictions/{task_id}/status` |
| Upload file | POST | `/files/upload` (multipart) |
| List models | GET | `/models` |
| Balance | GET | `/balance` |
| Usage | GET | `/usage` |
| Delete task | DELETE | `/predictions/{task_id}` |

**Async submit:**
```bash
curl -s -X POST "https://api.wavespeed.ai/api/v3/predictions/{model_id}" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"input": {"prompt": "A cat wearing sunglasses"}}'
# Response includes `id` for polling
```

**Sync submit** (blocks until done — add to body):
```json
{"input": {"prompt": "A cat"}, "enable_sync_mode": true}
```

**Poll:** Statuses: `pending` → `processing` → `completed` | `failed`. Result: `outputs` array of URLs.

## Model Categories

| Category | Key Models |
|----------|-----------|
| **Image** | `wavespeed-ai/flux-dev`, `wavespeed-ai/flux-schnell`, `wavespeed-ai/z-image`, `openai/dall-e-3`, `google/imagen-4`, `recraft/recraft-v3` |
| **Video** | `wavespeed-ai/wan-2.1`, `kling-ai/kling-2.0`, `openai/sora`, `google/veo-3`, `minimax/minimax-video-01`, `bytedance/seedance-1.0`, `vidu/vidu-2.0` |
| **Audio** | `ace-step/ace-step` (music), various TTS/voice-cloning models |
| **3D** | `tencent/hunyuan3d-2.0`, `meshy/meshy-6` |
| **Utilities** | Upscaler (2x/4x), face swap, background remover, try-on, OCR |

Use `wavespeed-helper.sh models` for the full current list.

## CLI Helper

```bash
# Generate (async with polling)
wavespeed-helper.sh generate "A cyberpunk city" --model wavespeed-ai/flux-dev

# Generate (sync — blocks until done)
wavespeed-helper.sh generate "A cat" --model wavespeed-ai/flux-schnell --sync

wavespeed-helper.sh status <task-id>   # Check task status
wavespeed-helper.sh models             # List available models
wavespeed-helper.sh upload image.jpg   # Upload file (returns URL for use as input)
wavespeed-helper.sh balance            # Account balance
wavespeed-helper.sh usage              # Usage stats
```

## MCP Integration (Optional)

```bash
pip install wavespeed-mcp
```

Claude Desktop config:
```json
{
  "mcpServers": {
    "wavespeed": {
      "command": "wavespeed-mcp",
      "env": { "WAVESPEED_API_KEY": "wsk_..." }
    }
  }
}
```

Source: [github.com/WaveSpeedAI/wavespeed-mcp](https://github.com/WaveSpeedAI/wavespeed-mcp)

## Integration with Content Pipeline

WaveSpeed is the unified generation backend for:
- `content/production-image.md` — image workflows
- `content/production-video.md` — video workflows
- `content/production-audio.md` — audio workflows

## Troubleshooting

**401 / Unauthorized:** Verify key is set (`echo "${WAVESPEED_API_KEY:+set}"`), starts with `wsk_`, and account has balance.

**Stuck in "processing":** Video models can take several minutes. Use `--timeout 600` for long tasks.

**Model not found:** IDs use `provider/model-name` format. Run `wavespeed-helper.sh models` for exact IDs — library updates frequently.

## Related

- [WaveSpeed AI Docs & API Reference](https://wavespeed.ai/docs)
- [WaveSpeed MCP Server](https://github.com/WaveSpeedAI/wavespeed-mcp)
- `tools/video/video-prompt-design.md` — Prompt engineering for video models
- `tools/vision/image-generation.md` — Image generation workflows

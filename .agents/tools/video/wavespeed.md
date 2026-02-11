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
- **API**: REST API at `https://api.wavespeed.ai/api/v3`
- **Auth**: Bearer token via `WAVESPEED_API_KEY` env var
- **CLI**: `wavespeed-helper.sh [generate|status|models|upload|balance|usage]`
- **MCP**: Optional — `pip install wavespeed-mcp` for Claude Desktop integration
- **SDKs**: Python (`pip install wavespeed`), JS (`npm install wavespeed`) — not used by helper

**When to use**:

- Generating images (Flux, DALL-E, Imagen, Z-Image, Recraft, etc.)
- Generating video (Wan, Kling, Sora, Veo, Minimax, HunyuanVideo, etc.)
- Audio generation (Ace Step music, TTS, voice cloning)
- 3D model generation (Hunyuan3D, Meshy6)
- Utility tasks (upscale, face swap, background removal, OCR, try-on)
- Any task requiring access to multiple AI providers through a single API

<!-- AI-CONTEXT-END -->

## Setup

### 1. Get API Key

1. Sign up at [wavespeed.ai](https://wavespeed.ai)
2. Go to [wavespeed.ai/accesskey](https://wavespeed.ai/accesskey)
3. Create a new API key

### 2. Store Credentials

```bash
aidevops secret set WAVESPEED_API_KEY
# Or plaintext fallback:
echo 'export WAVESPEED_API_KEY="wsk_..."' >> ~/.config/aidevops/credentials.sh
chmod 600 ~/.config/aidevops/credentials.sh
```

### 3. Test Connection

```bash
wavespeed-helper.sh balance
```

## API Reference

### Base URL

```text
https://api.wavespeed.ai/api/v3
```

All requests require `Authorization: Bearer $WAVESPEED_API_KEY` header.

### Submit Task (Async)

```bash
curl -s -X POST "https://api.wavespeed.ai/api/v3/predictions/{model_id}" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"input": {"prompt": "A cat wearing sunglasses"}}'
```

Response includes `id` for polling. Model ID format: `provider/model-name` (e.g., `wavespeed-ai/flux-dev`).

### Submit Task (Sync Mode)

Add `"enable_sync_mode": true` to skip polling — blocks until result is ready:

```bash
curl -s -X POST "https://api.wavespeed.ai/api/v3/predictions/{model_id}" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"input": {"prompt": "A cat"}, "enable_sync_mode": true}'
```

### Poll Status

```bash
curl -s "https://api.wavespeed.ai/api/v3/predictions/{task_id}/status" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY"
```

Statuses: `pending` → `processing` → `completed` | `failed`

Result on completion: `outputs` array containing URLs.

### Upload File

```bash
curl -s -X POST "https://api.wavespeed.ai/api/v3/files/upload" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY" \
  -F "file=@image.jpg"
```

Returns a URL to use as input for image-to-video, face swap, etc.

### List Models

```bash
curl -s "https://api.wavespeed.ai/api/v3/models" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY"
```

### Check Balance

```bash
curl -s "https://api.wavespeed.ai/api/v3/balance" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY"
```

### Check Usage

```bash
curl -s "https://api.wavespeed.ai/api/v3/usage" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY"
```

### Delete Task

```bash
curl -s -X DELETE "https://api.wavespeed.ai/api/v3/predictions/{task_id}" \
  -H "Authorization: Bearer $WAVESPEED_API_KEY"
```

## Model Categories

### Image Generation

| Model | Provider | Notes |
|-------|----------|-------|
| `wavespeed-ai/flux-dev` | WaveSpeed | Fast Flux variant |
| `wavespeed-ai/flux-schnell` | WaveSpeed | Fastest Flux |
| `wavespeed-ai/z-image` | WaveSpeed | High quality |
| `openai/dall-e-3` | OpenAI | DALL-E 3 |
| `google/imagen-4` | Google | Imagen 4 |
| `recraft/recraft-v3` | Recraft | Design-focused |

### Video Generation

| Model | Provider | Notes |
|-------|----------|-------|
| `wavespeed-ai/wan-2.1` | WaveSpeed | Text/image to video |
| `kling-ai/kling-2.0` | Kling | High quality video |
| `openai/sora` | OpenAI | Sora |
| `google/veo-3` | Google | Veo 3 |
| `minimax/minimax-video-01` | Minimax | Fast video |
| `bytedance/seedance-1.0` | ByteDance | Seedance |
| `vidu/vidu-2.0` | Vidu | Vidu 2.0 |

### Audio

| Model | Provider | Notes |
|-------|----------|-------|
| `ace-step/ace-step` | Ace Step | Music generation |
| Various TTS models | Multiple | Text-to-speech |

### 3D Generation

| Model | Provider | Notes |
|-------|----------|-------|
| `tencent/hunyuan3d-2.0` | Tencent | 3D model generation |
| `meshy/meshy-6` | Meshy | 3D from text/image |

### Utilities

| Model | Notes |
|-------|-------|
| Upscaler | Image upscaling (2x, 4x) |
| Face swap | Face replacement |
| Background remover | Remove/replace backgrounds |
| Try-on | Virtual clothing try-on |
| OCR | Text extraction from images |

Use `wavespeed-helper.sh models` to get the full current list.

## CLI Helper

```bash
# Generate with any model (async with polling)
wavespeed-helper.sh generate "A cyberpunk city" --model wavespeed-ai/flux-dev

# Generate with sync mode (single request, blocks until done)
wavespeed-helper.sh generate "A cat" --model wavespeed-ai/flux-schnell --sync

# Check task status
wavespeed-helper.sh status <task-id>

# List available models
wavespeed-helper.sh models

# Upload a file (returns URL for use as input)
wavespeed-helper.sh upload image.jpg

# Check account balance
wavespeed-helper.sh balance

# Check usage stats
wavespeed-helper.sh usage
```

## MCP Integration (Optional)

WaveSpeed provides an official MCP server for Claude Desktop:

```bash
pip install wavespeed-mcp
```

Configure in Claude Desktop settings:

```json
{
  "mcpServers": {
    "wavespeed": {
      "command": "wavespeed-mcp",
      "env": {
        "WAVESPEED_API_KEY": "wsk_..."
      }
    }
  }
}
```

Source: [github.com/WaveSpeedAI/wavespeed-mcp](https://github.com/WaveSpeedAI/wavespeed-mcp)

## Integration with Content Pipeline

WaveSpeed serves as a unified backend for content production:

- **Image generation**: Use via `content/production/image.md` workflows
- **Video generation**: Use via `content/production/video.md` workflows
- **Audio generation**: Use via `content/production/audio.md` workflows

The helper script can be called from other helpers and pipelines as a generation backend.

## Troubleshooting

### "Unauthorized" or 401

1. Verify key is set: `echo "${WAVESPEED_API_KEY:+set}"`
2. Verify key format starts with `wsk_`
3. Check balance — expired accounts return 401

### Task stuck in "processing"

Some models (especially video) can take several minutes. The helper polls with configurable interval and timeout. For long tasks, use `--timeout 600` (10 minutes).

### Model not found

Model IDs use `provider/model-name` format. Use `wavespeed-helper.sh models` to get exact IDs. The model library updates frequently as new models are added.

## Related

- [WaveSpeed AI Documentation](https://wavespeed.ai/docs)
- [WaveSpeed API Reference](https://wavespeed.ai/docs)
- [WaveSpeed MCP Server](https://github.com/WaveSpeedAI/wavespeed-mcp)
- `tools/video/video-prompt-design.md` — Prompt engineering for video models
- `tools/vision/image-generation.md` — Image generation workflows

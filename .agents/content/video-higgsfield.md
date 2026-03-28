---
description: "Higgsfield AI - Unified API for 100+ generative media models (image, video, voice, audio)"
mode: subagent
context7_id: /websites/higgsfield_ai
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

# Higgsfield AI API

Unified access to 100+ generative media models (images, videos, voice, audio) through a single API with automatic infrastructure scaling.

**Base URL**: `https://platform.higgsfield.ai`

**Use for**: text-to-image, image-to-video, character consistency across generations, multi-model comparison (FLUX, Kling, Seedance, etc.), webhook-based async pipelines.

## Quick Reference

| Endpoint | Purpose | Model |
|----------|---------|-------|
| `POST /v1/text2image/soul` | Text to image | Soul |
| `POST /v1/image2video/dop` | Image to video | DOP |
| `POST /higgsfield-ai/dop/standard` | Image to video | DOP Standard |
| `POST /kling-video/v2.1/pro/image-to-video` | Image to video | Kling v2.1 Pro |
| `POST /bytedance/seedance/v1/pro/image-to-video` | Image to video | Seedance v1 Pro |
| `POST /api/characters` | Create character | - |
| `GET /api/generation-results` | Poll job status | - |

## Authentication

**v1 endpoints** (`/v1/text2image/soul`, `/v1/image2video/dop`):

```bash
hf-api-key: {api-key}
hf-secret: {secret}
```

**Simplified endpoints** (`/higgsfield-ai/dop/standard`, Kling, Seedance):

```bash
Authorization: Key {api-key}:{secret}
```

Credentials in `~/.config/aidevops/credentials.sh`:

```bash
export HIGGSFIELD_API_KEY="your-api-key"
export HIGGSFIELD_SECRET="your-api-secret"
```

## Text-to-Image (Soul Model)

```bash
curl -X POST 'https://platform.higgsfield.ai/v1/text2image/soul' \
  --header 'hf-api-key: {api-key}' \
  --header 'hf-secret: {secret}' \
  --header 'Content-Type: application/json' \
  --data '{
    "params": {
      "prompt": "A serene mountain landscape at sunset",
      "width_and_height": "1696x960",
      "enhance_prompt": true,
      "quality": "1080p",
      "batch_size": 1
    }
  }'
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `prompt` | string | Yes | Text description of image |
| `width_and_height` | string | Yes | Dimensions (see supported sizes) |
| `enhance_prompt` | boolean | No | Auto-enhance prompt (default: false) |
| `quality` | string | No | `720p` or `1080p` (default: 1080p) |
| `batch_size` | integer | No | 1 or 4 (default: 1) |
| `seed` | integer | No | 1-1000000 for reproducibility |
| `style_id` | uuid | No | Preset style ID |
| `style_strength` | number | No | 0-1 (default: 1) |
| `custom_reference_id` | string | No | Character UUID for consistency |
| `custom_reference_strength` | number | No | 0-1 (default: 1) |
| `image_reference` | object | No | Reference image for guidance |

**Supported dimensions**: `1152x2048`, `2048x1152`, `2048x1536`, `1536x2048`, `1344x2016`, `2016x1344`, `960x1696`, `1536x1536`, `1536x1152`, `1696x960`, `1152x1536`, `1088x1632`, `1632x1088`

### Response

```json
{
  "id": "3c90c3cc-0d44-4b50-8888-8dd25736052a",
  "type": "text2image_soul",
  "created_at": "2023-11-07T05:31:56Z",
  "jobs": [{
    "id": "job-123",
    "status": "queued",
    "results": {
      "min": { "type": "image/png", "url": "https://..." },
      "raw": { "type": "image/png", "url": "https://..." }
    }
  }]
}
```

## Image-to-Video

### DOP Model (v1 endpoint)

```bash
curl -X POST 'https://platform.higgsfield.ai/v1/image2video/dop' \
  --header 'hf-api-key: {api-key}' \
  --header 'hf-secret: {secret}' \
  --header 'Content-Type: application/json' \
  --data '{
    "params": {
      "model": "dop-turbo",
      "prompt": "A cat walking gracefully through a garden",
      "input_images": [{
        "type": "image_url",
        "image_url": "https://example.com/cat.jpg"
      }],
      "enhance_prompt": true
    }
  }'
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `dop-turbo` or `dop-standard` |
| `prompt` | string | Yes | Animation description |
| `input_images` | array | Yes | Source image(s) |
| `input_images_end` | array | No | End frame image(s) |
| `motions` | array | No | Motion presets with strength |
| `seed` | integer | No | 1-1000000 for reproducibility |
| `enhance_prompt` | boolean | No | Auto-enhance prompt |

### Alternative Models (simplified API)

All use `Authorization: Key {api-key}:{secret}` and accept `image_url` + `prompt`:

| Model | Endpoint | Extra params |
|-------|----------|-------------|
| DOP Standard | `/higgsfield-ai/dop/standard` | `duration` (seconds) |
| Kling v2.1 Pro | `/kling-video/v2.1/pro/image-to-video` | - |
| Seedance v1 Pro | `/bytedance/seedance/v1/pro/image-to-video` | - |

```bash
curl -X POST 'https://platform.higgsfield.ai/higgsfield-ai/dop/standard' \
  --header 'Authorization: Key {api-key}:{secret}' \
  --header 'Content-Type: application/json' \
  --data '{
    "image_url": "https://example.com/image.jpg",
    "prompt": "Woman walks down Tokyo street with neon lights",
    "duration": 5
  }'
```

Kling and Seedance use the same request shape without `duration`.

## Character Consistency

Create reusable characters for consistent generation across images.

```bash
# Create character
curl -X POST 'https://platform.higgsfield.ai/api/characters' \
  --header 'hf-api-key: {api-key}' \
  --header 'hf-secret: {secret}' \
  --form 'photo=@/path/to/photo.jpg'
# Returns: { "id": "3eb3ad49-...", "photo_url": "https://cdn.higgsfield.ai/...", "created_at": "..." }
```

Use in generation by adding to `params`:

```json
{
  "custom_reference_id": "3eb3ad49-775d-40bd-b5e5-38b105108780",
  "custom_reference_strength": 0.9
}
```

## Webhook Integration

Add a `webhook` object to any generation request:

```json
{
  "webhook": { "url": "https://your-server.com/webhook", "secret": "your-webhook-secret" },
  "params": { "prompt": "..." }
}
```

## Job Status Polling

```bash
curl -X GET 'https://platform.higgsfield.ai/api/generation-results?id=job_789012' \
  --header 'hf-api-key: {api-key}' \
  --header 'hf-secret: {secret}'
```

```json
{
  "id": "job_789012",
  "status": "completed",
  "results": [{ "type": "image", "url": "https://cdn.higgsfield.ai/generations/img_123.jpg" }],
  "retention_expires_at": "2023-12-14T10:30:00Z"
}
```

**Status values**: `queued`, `processing`, `completed`, `failed`. Results retained 7 days.

## Python SDK

```bash
pip install higgsfield-client
```

SDK uses unified parameters (`resolution`, `aspect_ratio`) that differ from REST API (`width_and_height`, `quality`) -- translation handled internally.

```python
import higgsfield_client

# Synchronous
result = higgsfield_client.subscribe(
    'bytedance/seedream/v4/text-to-image',
    arguments={
        'prompt': 'A serene lake at sunset with mountains',
        'resolution': '2K',
        'aspect_ratio': '16:9'
    }
)
print(result['images'][0]['url'])

# Asynchronous: use subscribe_async() with await
```

## Error Handling

| Code | Type | Detail |
|------|------|--------|
| 401 | Authentication | Invalid or missing API credentials |
| 422 | Validation | `{"detail": [{"loc": ["body","params","prompt"], "msg": "Prompt cannot be empty", "type": "value_error"}]}` |
| 429 | Rate limit | Platform auto-scales; implement exponential backoff |

## Context7 Integration

```text
resolve-library-id("higgsfield")  # Returns: /websites/higgsfield_ai
query-docs("/websites/higgsfield_ai", "text-to-image parameters")
query-docs("/websites/higgsfield_ai", "image-to-video models")
query-docs("/websites/higgsfield_ai", "character consistency")
```

## API vs UI

| Feature | API (`video-higgsfield.md`) | UI (`video-higgsfield-ui.md`) |
|---------|---------------------------|-------------------------------|
| Auth | API key + secret | Email/password login |
| Credits | Pay-per-use API credits (separate pool) | Subscription credits (included in plan) |
| Models | Soul, Popcorn, Reve, Seedream v4, DOP, Kling 2.1/2.6/3.0, Seedance | All API models + Nano Banana Pro, GPT Image, Flux Kontext, Wan, Sora, Veo, MiniMax, Grok + 86 apps |
| Speed | Direct API calls (~5-30s) | Browser automation (~60s per generation) |
| Best for | Programmatic pipelines, batch processing | Subscription credits, UI-only features |

### Verified API Models (2026-02-10)

**Text-to-image**: `soul`, `soul-reference`, `soul-character`, `popcorn`, `popcorn-manual`, `seedream` (v4), `reve`

**Image-to-video**: `dop-standard`, `dop-lite`, `dop-turbo`, `dop-standard-flf`, `dop-lite-flf`, `dop-turbo-flf`, `kling-3.0`, `kling-2.6`, `kling-2.1`, `kling-2.1-master`, `seedance`, `seedance-lite`

**Image edit**: `seedream-edit`

**NOT on API** (web UI only): Nano Banana Pro, GPT Image, Flux Kontext, Seedream 4.5, Wan, Sora, Veo, MiniMax Hailuo, Grok Video

## Related

- **`./higgsfield-ui.md`** -- UI automation subagent (uses subscription credits via browser, no API key needed)
- [Higgsfield Docs](https://docs.higgsfield.ai/)
- [Higgsfield Dashboard](https://cloud.higgsfield.ai)
- `./remotion.md` -- Programmatic video editing

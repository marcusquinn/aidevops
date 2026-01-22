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

Higgsfield provides unified access to 100+ generative media models through a single API. Generate images, videos, voice, and audio with automatic infrastructure scaling.

## When to Use

Read this skill when working with:

- AI image generation (text-to-image)
- AI video generation (image-to-video)
- Character consistency across generations
- Multi-model comparison (FLUX, Kling, Seedance, etc.)
- Webhook-based async generation pipelines

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

**Base URL**: `https://platform.higgsfield.ai`

## Authentication

Higgsfield supports two authentication formats depending on the endpoint:

**Format 1: Header-based** (v1 endpoints like `/v1/text2image/soul`, `/v1/image2video/dop`):

```bash
hf-api-key: {api-key}
hf-secret: {secret}
```

**Format 2: Authorization header** (simplified endpoints like `/higgsfield-ai/dop/standard`):

```bash
Authorization: Key {api-key}:{secret}
```

Store credentials in `~/.config/aidevops/mcp-env.sh`:

```bash
export HIGGSFIELD_API_KEY="your-api-key"
export HIGGSFIELD_SECRET="your-api-secret"
```

## Text-to-Image (Soul Model)

Generate images from text prompts with optional character consistency.

### Basic Request

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
| `custom_reference_id` | string | No | Character ID for consistency (UUID format) |
| `custom_reference_strength` | number | No | 0-1 (default: 1) |
| `image_reference` | object | No | Reference image for guidance |

### Supported Dimensions

```
1152x2048, 2048x1152, 2048x1536, 1536x2048,
1344x2016, 2016x1344, 960x1696, 1536x1536,
1536x1152, 1696x960, 1152x1536, 1088x1632, 1632x1088
```

### Response

```json
{
  "id": "3c90c3cc-0d44-4b50-8888-8dd25736052a",
  "type": "text2image_soul",
  "created_at": "2023-11-07T05:31:56Z",
  "jobs": [
    {
      "id": "job-123",
      "status": "queued",
      "results": {
        "min": { "type": "image/png", "url": "https://..." },
        "raw": { "type": "image/png", "url": "https://..." }
      }
    }
  ]
}
```

## Image-to-Video (DOP Model)

Transform static images into animated videos.

### Basic Request

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

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `model` | string | Yes | `dop-turbo` or `dop-standard` |
| `prompt` | string | Yes | Animation description |
| `input_images` | array | Yes | Source image(s) |
| `input_images_end` | array | No | End frame image(s) |
| `motions` | array | No | Motion presets with strength |
| `seed` | integer | No | 1-1000000 for reproducibility |
| `enhance_prompt` | boolean | No | Auto-enhance prompt |

### Alternative Models

**DOP Standard** (simpler API):

```bash
curl -X POST 'https://platform.higgsfield.ai/higgsfield-ai/dop/standard' \
  --header 'Authorization: Key {api_key}:{api_secret}' \
  --header 'Content-Type: application/json' \
  --data '{
    "image_url": "https://example.com/image.jpg",
    "prompt": "Woman walks down Tokyo street with neon lights",
    "duration": 5
  }'
```

**Kling v2.1 Pro** (cinematic):

```bash
curl -X POST 'https://platform.higgsfield.ai/kling-video/v2.1/pro/image-to-video' \
  --header 'Authorization: Key {api_key}:{api_secret}' \
  --header 'Content-Type: application/json' \
  --data '{
    "image_url": "https://example.com/landscape.jpg",
    "prompt": "Camera slowly pans across landscape as clouds drift"
  }'
```

**Seedance v1 Pro** (professional):

```bash
curl -X POST 'https://platform.higgsfield.ai/bytedance/seedance/v1/pro/image-to-video' \
  --header 'Authorization: Key {api_key}:{api_secret}' \
  --header 'Content-Type: application/json' \
  --data '{
    "image_url": "https://example.com/portrait.jpg",
    "prompt": "Subject turns head slightly and smiles"
  }'
```

## Character Consistency

Create reusable characters for consistent image generation.

### Create Character

```bash
curl -X POST 'https://platform.higgsfield.ai/api/characters' \
  --header 'hf-api-key: {api-key}' \
  --header 'hf-secret: {secret}' \
  --form 'photo=@/path/to/photo.jpg'
```

Response:

```json
{
  "id": "3eb3ad49-775d-40bd-b5e5-38b105108780",
  "photo_url": "https://cdn.higgsfield.ai/characters/photo_123.jpg",
  "created_at": "2023-12-07T10:30:00Z"
}
```

### Use Character in Generation

```json
{
  "params": {
    "prompt": "Character sitting in a coffee shop",
    "custom_reference_id": "3eb3ad49-775d-40bd-b5e5-38b105108780",
    "custom_reference_strength": 0.9
  }
}
```

## Webhook Integration

Receive notifications when jobs complete.

```json
{
  "webhook": {
    "url": "https://your-server.com/webhook",
    "secret": "your-webhook-secret"
  },
  "params": {
    "prompt": "..."
  }
}
```

## Job Status Polling

Check generation status and retrieve results.

```bash
curl -X GET 'https://platform.higgsfield.ai/api/generation-results?id=job_789012' \
  --header 'hf-api-key: {api-key}' \
  --header 'hf-secret: {secret}'
```

Response:

```json
{
  "id": "job_789012",
  "status": "completed",
  "results": [{
    "type": "image",
    "url": "https://cdn.higgsfield.ai/generations/img_123.jpg"
  }],
  "retention_expires_at": "2023-12-14T10:30:00Z"
}
```

**Status values**: `pending`, `processing`, `completed`, `failed`

**Note**: Results are retained for 7 days.

## Python SDK

Install:

```bash
pip install higgsfield-client
```

The SDK provides a simplified interface that abstracts the REST API. It supports multiple models with unified parameters.

### Synchronous

```python
import higgsfield_client

# Using Seedream model (SDK-specific simplified interface)
result = higgsfield_client.subscribe(
    'bytedance/seedream/v4/text-to-image',
    arguments={
        'prompt': 'A serene lake at sunset with mountains',
        'resolution': '2K',
        'aspect_ratio': '16:9'
    }
)

print(result['images'][0]['url'])
```

### Asynchronous

```python
import asyncio
import higgsfield_client

async def main():
    result = await higgsfield_client.subscribe_async(
        'bytedance/seedream/v4/text-to-image',
        arguments={
            'prompt': 'A serene lake at sunset with mountains',
            'resolution': '2K',
            'aspect_ratio': '16:9'
        }
    )
    print(result['images'][0]['url'])

asyncio.run(main())
```

**Note**: The SDK uses simplified parameters (`resolution`, `aspect_ratio`) that differ from the REST API (`width_and_height`, `quality`). The SDK handles the translation internally.

## Error Handling

### Validation Error (422)

```json
{
  "detail": [
    {
      "loc": ["body", "params", "prompt"],
      "msg": "Prompt cannot be empty",
      "type": "value_error"
    }
  ]
}
```

### Authentication Error (401)

Invalid or missing API credentials.

### Rate Limiting

The platform auto-scales, but implement exponential backoff for resilience.

## Context7 Integration

For up-to-date API documentation:

```
resolve-library-id("higgsfield")
# Returns: /websites/higgsfield_ai

query-docs("/websites/higgsfield_ai", "text-to-image parameters")
query-docs("/websites/higgsfield_ai", "image-to-video models")
query-docs("/websites/higgsfield_ai", "character consistency")
```

## Related

- [Higgsfield Docs](https://docs.higgsfield.ai/)
- [Higgsfield Dashboard](https://cloud.higgsfield.ai)
- `tools/video/remotion.md` - Programmatic video editing
- `tools/browser/stagehand.md` - Browser automation for assets

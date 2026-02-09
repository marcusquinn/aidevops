---
description: "Image generation - text-to-image models for creating visuals from prompts"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: true
---

# Image Generation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate images from text prompts using AI models
- **Cloud**: DALL-E 3 (OpenAI), Midjourney, Google Imagen 3, Ideogram
- **Local**: FLUX (Black Forest Labs), Stable Diffusion XL (Stability AI)
- **Workflow tool**: ComfyUI (node-based, local), Automatic1111 (web UI, local)

**When to use**: Creating product images, concept art, marketing visuals, UI mockups, social media graphics, or any task requiring new images from text descriptions.

**Quick start** (cloud):

```bash
# DALL-E 3 via OpenAI API
curl https://api.openai.com/v1/images/generations \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "dall-e-3",
    "prompt": "A professional product photo of a laptop on a clean desk",
    "size": "1024x1024",
    "quality": "hd"
  }'
```

**Quick start** (local):

```bash
# FLUX via ComfyUI (requires GPU with 12GB+ VRAM)
# See ComfyUI setup section below
```

<!-- AI-CONTEXT-END -->

## Model Comparison

| Model | Provider | Quality | Speed | Cost | Local | Best For |
|-------|----------|---------|-------|------|-------|----------|
| **DALL-E 3** | OpenAI | High | Fast | $0.04-0.12/img | No | General purpose, text rendering |
| **Midjourney v6** | Midjourney | Very high | Medium | $10-60/mo | No | Artistic, photorealistic |
| **Imagen 3** | Google | High | Fast | API pricing | No | Photorealism, Google ecosystem |
| **Ideogram 2.0** | Ideogram | High | Fast | Free tier + paid | No | Text in images, logos |
| **FLUX.1 [dev]** | Black Forest Labs | High | Medium | Free (local) | Yes | Open-source, customisable |
| **FLUX.1 [schnell]** | Black Forest Labs | Good | Fast | Free (local) | Yes | Fast local generation |
| **SD XL** | Stability AI | Good | Fast | Free (local) | Yes | Established ecosystem, ControlNet |
| **SD 3.5** | Stability AI | High | Medium | Free (local) | Yes | Latest Stability model |

### Choosing a Model

```text
Need text rendered in images?     → DALL-E 3 or Ideogram
Need photorealistic quality?      → Midjourney or Imagen 3
Need full local control?          → FLUX.1 [dev] or SD XL
Need fast iteration (local)?      → FLUX.1 [schnell]
Need ControlNet / img2img?        → SD XL (most mature ecosystem)
Need API integration?             → DALL-E 3 (simplest API)
Budget-conscious?                 → FLUX or SD locally (GPU cost only)
```

## Cloud APIs

### DALL-E 3 (OpenAI)

```bash
# Store API key
aidevops secret set OPENAI_API_KEY

# Generate image
curl https://api.openai.com/v1/images/generations \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "dall-e-3",
    "prompt": "A minimalist logo for a tech startup called Nexus",
    "size": "1024x1024",
    "quality": "hd",
    "style": "natural"
  }'
```

| Parameter | Options | Notes |
|-----------|---------|-------|
| `size` | 1024x1024, 1024x1792, 1792x1024 | Square, portrait, landscape |
| `quality` | standard, hd | HD costs 2x but significantly better |
| `style` | natural, vivid | Natural = photorealistic, vivid = artistic |
| `n` | 1 | DALL-E 3 only supports 1 image per request |

**Pricing**: Standard $0.04/img, HD $0.08/img (1024x1024). Larger sizes cost more.

**Strengths**: Excellent text rendering, good prompt adherence, simple API.

**Limitations**: No inpainting in v3 API (use v2 for edits), 1 image per request, no negative prompts.

### Midjourney

Midjourney operates via Discord bot or web interface (no REST API at time of writing).

**Access**: Subscribe at [midjourney.com](https://www.midjourney.com/), use via Discord `/imagine` command or web UI.

**Prompt tips**:

- Use `--ar 16:9` for aspect ratio
- Use `--v 6` for latest model
- Use `--style raw` for less stylised output
- Use `--no text, watermark` for negative prompts

### Google Imagen 3

Available via Vertex AI API or Google AI Studio.

```bash
# Via Vertex AI (requires Google Cloud project)
curl -X POST \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/$PROJECT_ID/locations/us-central1/publishers/google/models/imagen-3.0-generate-002:predict" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{
    "instances": [{"prompt": "A serene mountain landscape at sunset"}],
    "parameters": {"sampleCount": 1, "aspectRatio": "16:9"}
  }'
```

## Local Generation

### ComfyUI (Recommended)

Node-based workflow tool for local image generation. Supports FLUX, SD XL, ControlNet, and custom pipelines.

```bash
# Install ComfyUI
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
pip install -r requirements.txt

# Download FLUX model (~12GB)
# Place in ComfyUI/models/checkpoints/
# Download from https://huggingface.co/black-forest-labs/FLUX.1-dev

# Start ComfyUI
python main.py --listen 0.0.0.0 --port 8188

# Access at http://localhost:8188
```

**VRAM requirements**:

| Model | Min VRAM | Recommended |
|-------|----------|-------------|
| FLUX.1 [schnell] | 8GB | 12GB+ |
| FLUX.1 [dev] | 12GB | 16GB+ |
| SD XL | 6GB | 8GB+ |
| SD 3.5 | 8GB | 12GB+ |

### ComfyUI API (Headless)

```bash
# Queue a prompt via API (headless generation)
curl -X POST http://localhost:8188/prompt \
  -H "Content-Type: application/json" \
  -d '{"prompt": <workflow-json>}'

# Check queue status
curl http://localhost:8188/queue

# Get generated image
curl http://localhost:8188/view?filename=<output-filename>
```

### Ollama (Simple Local)

Some vision models in Ollama can generate image descriptions but not images. For generation, use ComfyUI or Automatic1111.

## Prompt Engineering

### General Principles

1. **Be specific**: "A golden retriever puppy sitting on a red velvet cushion" > "a dog"
2. **Include style**: "oil painting style", "photorealistic", "minimalist vector"
3. **Specify lighting**: "soft natural light", "dramatic side lighting", "studio lighting"
4. **Add composition**: "close-up", "wide angle", "bird's eye view", "rule of thirds"
5. **Set mood**: "warm and inviting", "dark and moody", "bright and cheerful"

### Negative Prompts (SD/FLUX)

```text
Useful negatives for quality:
blurry, low quality, distorted, deformed, ugly, duplicate, watermark,
text, signature, oversaturated, underexposed, overexposed
```

### Batch Generation Script

```bash
#!/usr/bin/env bash
# Generate multiple variations via DALL-E 3
set -euo pipefail

local prompt="$1"
local count="${2:-4}"
local output_dir="${3:-.}"

for i in $(seq 1 "$count"); do
  echo "Generating image $i/$count..."
  curl -s https://api.openai.com/v1/images/generations \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\": \"dall-e-3\", \"prompt\": \"$prompt\", \"size\": \"1024x1024\", \"quality\": \"hd\"}" \
    | python3 -c "import json,sys,urllib.request; url=json.load(sys.stdin)['data'][0]['url']; urllib.request.urlretrieve(url, '$output_dir/gen_$i.png')"
  echo "Saved: $output_dir/gen_$i.png"
done
```

## Cost Comparison

| Model | Per Image | Monthly (100 imgs) | Notes |
|-------|-----------|---------------------|-------|
| DALL-E 3 HD | $0.08 | $8 | Pay per image |
| Midjourney Basic | $0.10 | $10/mo (200 imgs) | Subscription |
| Imagen 3 | ~$0.04 | ~$4 | Vertex AI pricing |
| FLUX (local) | ~$0.01 | GPU electricity only | Requires 12GB+ VRAM |
| SD XL (local) | ~$0.005 | GPU electricity only | Requires 8GB+ VRAM |
| FLUX (cloud GPU) | ~$0.02 | ~$2 + GPU rental | RunPod/Vast.ai |

## See Also

- `overview.md` - Vision AI category overview
- `image-editing.md` - Modify existing images
- `image-understanding.md` - Analyse existing images
- `tools/video/video-prompt-design.md` - Video prompt engineering (related techniques)
- `tools/infrastructure/cloud-gpu.md` - GPU deployment for local models

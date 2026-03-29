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

```text
Text in images?       → DALL-E 3 or Ideogram
Photorealistic?       → Midjourney or Imagen 3
Full local control?   → FLUX.1 [dev] or SD XL
Fast local iteration? → FLUX.1 [schnell]
ControlNet / img2img? → SD XL (most mature ecosystem)
Simplest API?         → DALL-E 3
Budget-conscious?     → FLUX or SD locally (GPU cost only)
```

## Cloud APIs

### DALL-E 3 (OpenAI)

```bash
aidevops secret set OPENAI_API_KEY

curl https://api.openai.com/v1/images/generations \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "dall-e-3", "prompt": "...", "size": "1024x1024", "quality": "hd", "style": "natural"}'
```

| Parameter | Options | Notes |
|-----------|---------|-------|
| `size` | 1024x1024, 1024x1792, 1792x1024 | Square, portrait, landscape |
| `quality` | standard, hd | Standard $0.04, HD $0.08/image |
| `style` | natural, vivid | Natural = photorealistic, vivid = artistic |
| `n` | 1 | DALL-E 3 supports 1/request; use v2 API for edits |

### Midjourney

No REST API — use Discord `/imagine` or [midjourney.com](https://www.midjourney.com/).

Flags: `--ar 16:9` (aspect) · `--v 6` (model) · `--style raw` (less stylised) · `--no text, watermark` (negatives)

### Google Imagen 3

```bash
curl -X POST \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/$PROJECT_ID/locations/us-central1/publishers/google/models/imagen-3.0-generate-002:predict" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{"instances": [{"prompt": "..."}], "parameters": {"sampleCount": 1, "aspectRatio": "16:9"}}'
```

## Local Generation (ComfyUI)

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI && pip install -r requirements.txt
# Download FLUX model (~12GB) to ComfyUI/models/checkpoints/
# https://huggingface.co/black-forest-labs/FLUX.1-dev
python main.py --listen 0.0.0.0 --port 8188
```

| Model | Min VRAM | Recommended |
|-------|----------|-------------|
| FLUX.1 [schnell] | 8GB | 12GB+ |
| FLUX.1 [dev] | 12GB | 16GB+ |
| SD XL | 6GB | 8GB+ |
| SD 3.5 | 8GB | 12GB+ |

**Headless API**:

```bash
curl -X POST http://localhost:8188/prompt -H "Content-Type: application/json" -d '{"prompt": <workflow-json>}'
curl http://localhost:8188/queue
curl "http://localhost:8188/view?filename=<output-filename>"
```

## Prompt Engineering

Structure: subject + style + lighting + composition + mood.

Example: `"A golden retriever puppy on red velvet, oil painting, soft natural light, close-up, warm and inviting"`

**Negative prompts (SD/FLUX)**:

```text
blurry, low quality, distorted, deformed, ugly, duplicate, watermark,
text, signature, oversaturated, underexposed, overexposed
```

**Batch generation (DALL-E 3)**:

```bash
#!/usr/bin/env bash
set -euo pipefail

generate_batch() {
  local prompt="$1"
  local count="${2:-4}"
  local output_dir="${3:-.}"

  for i in $(seq 1 "$count"); do
    curl -s https://api.openai.com/v1/images/generations \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"model\": \"dall-e-3\", \"prompt\": \"$prompt\", \"size\": \"1024x1024\", \"quality\": \"hd\"}" \
      | python3 -c "import json,sys,urllib.request; url=json.load(sys.stdin)['data'][0]['url']; urllib.request.urlretrieve(url, '$output_dir/gen_$i.png')"
    echo "Saved: $output_dir/gen_$i.png"
  done
  return 0
}

generate_batch "$@"
```

## See Also

- `overview.md` - Vision AI category overview
- `image-editing.md` - Modify existing images
- `image-understanding.md` - Analyse existing images
- `tools/video/video-prompt-design.md` - Video prompt engineering (related techniques)
- `tools/infrastructure/cloud-gpu.md` - GPU deployment for local models

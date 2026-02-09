---
description: "Image editing - AI-powered inpainting, outpainting, upscaling, and style transfer"
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

# Image Editing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Modify existing images using AI - inpainting, outpainting, upscaling, style transfer, background removal
- **Cloud**: DALL-E 2 edit API, Google Imagen edit, Adobe Firefly
- **Local**: Stable Diffusion inpaint, FLUX fill, Real-ESRGAN (upscaling), ControlNet
- **Workflow tool**: ComfyUI (node-based pipelines for complex edits)

**When to use**: Removing objects from images, extending image boundaries, changing styles, upscaling low-resolution images, removing backgrounds, or applying consistent edits across batches.

**Quick start** (cloud):

```bash
# DALL-E 2 image edit (inpainting)
curl https://api.openai.com/v1/images/edits \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F image="@original.png" \
  -F mask="@mask.png" \
  -F prompt="A sunlit garden with flowers" \
  -F size="1024x1024"
```

<!-- AI-CONTEXT-END -->

## Editing Capabilities

| Capability | Description | Best Tool |
|------------|-------------|-----------|
| **Inpainting** | Replace selected region with AI-generated content | SD inpaint, DALL-E 2 edit |
| **Outpainting** | Extend image beyond original boundaries | SD outpaint, FLUX fill |
| **Upscaling** | Increase resolution with AI enhancement | Real-ESRGAN, Topaz |
| **Background removal** | Remove or replace backgrounds | rembg, Segment Anything |
| **Style transfer** | Apply artistic style to existing image | SD img2img, ControlNet |
| **ControlNet** | Guide generation with edge/depth/pose maps | SD XL + ControlNet |
| **Face restoration** | Enhance/restore faces in images | GFPGAN, CodeFormer |

## Cloud APIs

### DALL-E 2 Edit (OpenAI)

The edit endpoint uses DALL-E 2 (not DALL-E 3). Requires a source image and a mask indicating the area to edit.

```bash
# Inpainting: replace masked area
curl https://api.openai.com/v1/images/edits \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F image="@photo.png" \
  -F mask="@mask.png" \
  -F prompt="A red sports car" \
  -F size="1024x1024" \
  -F n=1

# Variation: generate similar images
curl https://api.openai.com/v1/images/variations \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F image="@photo.png" \
  -F size="1024x1024" \
  -F n=3
```

**Requirements**: Image and mask must be square PNG files, same dimensions, under 4MB. Mask transparent areas indicate where to edit.

### Google Imagen Edit (Vertex AI)

```bash
# Inpainting via Vertex AI
curl -X POST \
  "https://us-central1-aiplatform.googleapis.com/v1/projects/$PROJECT_ID/locations/us-central1/publishers/google/models/imagen-3.0-capability-001:predict" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "Content-Type: application/json" \
  -d '{
    "instances": [{
      "prompt": "Replace with a modern office",
      "image": {"bytesBase64Encoded": "<base64-image>"},
      "mask": {"image": {"bytesBase64Encoded": "<base64-mask>"}}
    }],
    "parameters": {"sampleCount": 1}
  }'
```

## Local Tools

### Stable Diffusion Inpainting (ComfyUI)

```bash
# Install ComfyUI (if not already)
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI && pip install -r requirements.txt

# Download inpainting model
# Place SD XL inpaint model in ComfyUI/models/checkpoints/
# Available from https://huggingface.co/diffusers/stable-diffusion-xl-1.0-inpainting-0.1

# Start ComfyUI
python main.py --listen 0.0.0.0 --port 8188
```

Use the ComfyUI web interface to build inpainting workflows with mask painting tools.

### Real-ESRGAN (Upscaling)

```bash
# Install
pip install realesrgan

# Upscale 4x
python -m realesrgan -i input.jpg -o output.jpg -s 4

# Upscale with face enhancement
python -m realesrgan -i input.jpg -o output.jpg -s 4 --face_enhance
```

| Scale | Use Case | Notes |
|-------|----------|-------|
| 2x | Moderate enhancement | Fast, subtle |
| 4x | Standard upscaling | Good balance |
| 8x | Maximum enlargement | Slower, may introduce artifacts |

### rembg (Background Removal)

```bash
# Install
pip install rembg[gpu]  # GPU accelerated
# or
pip install rembg        # CPU only

# Remove background
rembg i input.jpg output.png

# Batch process
rembg p input_dir/ output_dir/

# With alpha matting (better edges)
rembg i -a input.jpg output.png
```

### GFPGAN (Face Restoration)

```bash
# Install
pip install gfpgan

# Restore faces
python -m gfpgan.inference -i input.jpg -o output/ -v 1.4 -s 2
```

### ControlNet (Guided Generation)

ControlNet allows precise control over image generation using structural guides:

| Control Type | Input | Use Case |
|-------------|-------|----------|
| **Canny edge** | Edge map | Preserve structure, change style |
| **Depth** | Depth map | Maintain spatial layout |
| **OpenPose** | Pose skeleton | Control character poses |
| **Scribble** | Hand-drawn sketch | Sketch to image |
| **Segmentation** | Semantic map | Control scene composition |
| **Tile** | Low-res image | Upscale with detail generation |

ControlNet models are used within ComfyUI or Automatic1111 workflows.

## Common Workflows

### Product Photo Enhancement

```text
1. Remove background (rembg)
2. Upscale if needed (Real-ESRGAN 2x)
3. Generate new background (SD inpaint or DALL-E)
4. Colour correct and adjust (ImageMagick or Pillow)
```

### Batch Background Removal

```bash
#!/usr/bin/env bash
set -euo pipefail

local input_dir="$1"
local output_dir="$2"

mkdir -p "$output_dir"

for img in "$input_dir"/*.{jpg,png,webp}; do
  [ -f "$img" ] || continue
  local basename
  basename="$(basename "${img%.*}")"
  echo "Processing: $basename"
  rembg i "$img" "$output_dir/${basename}.png"
done

echo "Done. Output in: $output_dir"
```

### Image Resize and Optimise

```bash
# Using ImageMagick (non-AI but commonly needed alongside AI editing)
# Resize to max 1920px width, maintain aspect ratio
magick input.jpg -resize 1920x\> -quality 85 output.jpg

# Convert to WebP for web
magick input.jpg -resize 1920x\> -quality 80 output.webp

# Batch convert directory
magick mogrify -resize 1920x\> -quality 85 -path output/ input/*.jpg
```

## VRAM Requirements

| Tool | Min VRAM | Recommended | Notes |
|------|----------|-------------|-------|
| SD XL inpaint | 6GB | 8GB+ | Standard inpainting |
| FLUX fill | 12GB | 16GB+ | Higher quality |
| ControlNet | 8GB | 12GB+ | Adds ~2GB to base model |
| Real-ESRGAN | 2GB | 4GB+ | Lightweight |
| rembg (GPU) | 2GB | 4GB+ | Fast with GPU |
| GFPGAN | 2GB | 4GB+ | Face-specific |

For cloud GPU deployment of these tools, see `tools/infrastructure/cloud-gpu.md`.

## See Also

- `overview.md` - Vision AI category overview
- `image-generation.md` - Create new images from text
- `image-understanding.md` - Analyse existing images
- `tools/infrastructure/cloud-gpu.md` - GPU deployment for local models
- `tools/video/` - Image-to-video pipelines

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

- **Purpose**: Modify existing images — inpainting, outpainting, upscaling, style transfer, background removal, batch edits
- **Cloud**: DALL-E 2 edit API, Google Imagen edit, Adobe Firefly
- **Local**: Stable Diffusion inpaint, FLUX fill, Real-ESRGAN (upscaling), ControlNet
- **Workflow tool**: ComfyUI (node-based pipelines for complex edits)

<!-- AI-CONTEXT-END -->

## Editing Capabilities

| Capability | Description | Best Tool |
|------------|-------------|-----------|
| **Inpainting** | Replace selected region with AI content | SD inpaint, DALL-E 2 edit |
| **Outpainting** | Extend image beyond original boundaries | SD outpaint, FLUX fill |
| **Upscaling** | Increase resolution with AI enhancement | Real-ESRGAN, Topaz |
| **Background removal** | Remove or replace backgrounds | rembg, Segment Anything |
| **Style transfer** | Apply artistic style to existing image | SD img2img, ControlNet |
| **ControlNet** | Guide generation with edge/depth/pose maps | SD XL + ControlNet |
| **Face restoration** | Enhance/restore faces in images | GFPGAN, CodeFormer |

## Cloud APIs

### DALL-E 2 Edit (OpenAI)

DALL-E 2 only (not 3). Source + mask: square PNGs, same dimensions, <4MB. Transparent mask areas = edit region.

```bash
# Inpainting: replace masked area
curl https://api.openai.com/v1/images/edits \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F image="@photo.png" -F mask="@mask.png" \
  -F prompt="A red sports car" -F size="1024x1024" -F n=1

# Variation: generate similar images
curl https://api.openai.com/v1/images/variations \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -F image="@photo.png" -F size="1024x1024" -F n=3
```

### Google Imagen Edit (Vertex AI)

```bash
curl -X POST "https://us-central1-aiplatform.googleapis.com/v1/projects/$PROJECT_ID/locations/us-central1/publishers/google/models/imagen-3.0-capability-001:predict" \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" -H "Content-Type: application/json" \
  -d '{"instances": [{"prompt": "Replace with a modern office", "image": {"bytesBase64Encoded": "<base64>"}, "mask": {"image": {"bytesBase64Encoded": "<base64>"}}}], "parameters": {"sampleCount": 1}}'
```

## Local Tools

### Stable Diffusion Inpainting (ComfyUI)

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git && cd ComfyUI && pip install -r requirements.txt
# SD XL inpaint model → models/checkpoints/ (https://huggingface.co/diffusers/stable-diffusion-xl-1.0-inpainting-0.1)
python main.py --listen 0.0.0.0 --port 8188  # web UI includes mask painting
```

### Real-ESRGAN (Upscaling)

```bash
pip install realesrgan
python -m realesrgan -i input.jpg -o output.jpg -s 4                 # 4x upscale
python -m realesrgan -i input.jpg -o output.jpg -s 4 --face_enhance  # + face enhancement
```

Scales: **2x** (fast) · **4x** (standard) · **8x** (max, may artifact)

### rembg (Background Removal)

```bash
pip install rembg[gpu]  # or `rembg` for CPU-only
rembg i input.jpg output.png      # single image
rembg p input_dir/ output_dir/    # batch
rembg i -a input.jpg output.png   # alpha matting (better edges)
```

### GFPGAN (Face Restoration)

`pip install gfpgan && python -m gfpgan.inference -i input.jpg -o output/ -v 1.4 -s 2`

### ControlNet (Guided Generation)

Structural guides for precise control. Used within ComfyUI or Automatic1111.

| Control Type | Input | Use Case |
|-------------|-------|----------|
| **Canny edge** | Edge map | Preserve structure, change style |
| **Depth** | Depth map | Maintain spatial layout |
| **OpenPose** | Pose skeleton | Control character poses |
| **Scribble** | Hand-drawn sketch | Sketch to image |
| **Segmentation** | Semantic map | Control scene composition |
| **Tile** | Low-res image | Upscale with detail generation |

## Common Workflows

### Product Photo Enhancement

`rembg` → Real-ESRGAN 2x (if needed) → SD inpaint / DALL-E (new background) → ImageMagick / Pillow (colour correct)

### Batch Background Removal

```bash
mkdir -p out && for img in input/*.{jpg,png,webp}; do [ -f "$img" ] && rembg i "$img" "out/$(basename "${img%.*}").png"; done
```

### Image Resize and Optimise (ImageMagick)

```bash
magick input.jpg -resize 1920x\> -quality 85 output.jpg               # resize, keep aspect
magick input.jpg -resize 1920x\> -quality 80 output.webp              # to WebP
magick mogrify -resize 1920x\> -quality 85 -path output/ input/*.jpg  # batch
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

**See also**: `overview.md` · `image-generation.md` · `image-understanding.md` · `tools/infrastructure/cloud-gpu.md` (cloud GPU deployment) · `tools/video/`

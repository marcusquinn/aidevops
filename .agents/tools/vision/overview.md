---
description: "Vision AI tools overview - image generation, understanding, and editing model selection"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: true
---

# Vision AI Tools

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Route image tasks to the right generation, understanding, or editing guide
- **Create images**: `image-generation.md` — DALL-E 3, Midjourney, FLUX, Stable Diffusion
- **Analyze images**: `image-understanding.md` — GPT-4o vision, Claude vision, Gemini, LLaVA, Qwen-VL
- **Edit images**: `image-editing.md` — DALL-E 3 edit, Stable Diffusion inpaint, FLUX fill
- **Local stack**: Ollama for VLMs; ComfyUI for generation/editing; `tools/infrastructure/cloud-gpu.md` for GPU deployment
- **Specialized routes**: OCR → `tools/ocr/glm-ocr.md`; GUI screenshots → `tools/browser/peekaboo.md`

<!-- AI-CONTEXT-END -->

## Selection Guide

| Need | Route | Best Options | Deployment Notes |
|------|-------|--------------|------------------|
| Text-to-image, concept art, marketing assets | `image-generation.md` | DALL-E 3, Midjourney, FLUX, Stable Diffusion | Cloud APIs are fastest to integrate; ComfyUI gives local control |
| Image analysis, captioning, visual Q&A | `image-understanding.md` | GPT-4o vision, Claude vision, Gemini, LLaVA, Qwen-VL | Ollama fits privacy-sensitive local analysis; cloud models fit large-context reasoning |
| Inpainting, outpainting, style transfer | `image-editing.md` | DALL-E 3 edit, Stable Diffusion inpaint, FLUX fill | ComfyUI is the main local editing stack |
| Product photos / marketing visuals | `image-generation.md` | DALL-E 3 (cloud), FLUX (local) | Choose cloud for speed, local for cost/control |
| Code screenshots, diagrams, alt text | `image-understanding.md` | Claude vision, GPT-4o vision, Gemini, LLaVA | Gemini and GPT-4o fit large diagrams; LLaVA fits local captioning |
| Documents, receipts, GUI screenshots | `tools/ocr/glm-ocr.md` or `tools/browser/peekaboo.md` | GLM-OCR, Peekaboo | Prefer dedicated OCR or browser capture flows over general VLM analysis |
| Background removal, upscaling, enhancement | `image-editing.md` | Stable Diffusion inpaint, DALL-E 3 edit, Real-ESRGAN, Topaz | Local tools are strongest for enhancement workflows |

## Deployment Options

| Deployment | Models | Best For |
|------------|--------|----------|
| **Cloud API** | DALL-E 3, GPT-4o vision, Claude vision, Gemini, Midjourney | Fast integration, no GPU needed |
| **Local (Ollama)** | LLaVA, MiniCPM-o, Qwen-VL | Private understanding tasks, no API cost |
| **Local (ComfyUI)** | FLUX, Stable Diffusion XL, ControlNet | Generation, editing, workflow control |
| **Cloud GPU** | Any model via vLLM/ComfyUI | Scale, large local models, batch processing |

## Integration with aidevops

| Integration | Description |
|-------------|-------------|
| `tools/ocr/glm-ocr.md` | Dedicated OCR (prefer over general vision for text extraction) |
| `tools/browser/peekaboo.md` | Screen capture + vision analysis for GUI automation |
| `tools/video/` | Image-to-video pipelines (Kling, Seedance via Higgsfield) |
| `tools/infrastructure/cloud-gpu.md` | GPU deployment for local vision models |
| `content/` | AI-generated images for content workflows |

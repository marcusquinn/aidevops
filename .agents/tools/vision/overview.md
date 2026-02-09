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

- **Purpose**: Select and use visual AI models for image generation, understanding, and editing
- **Categories**: Generation (text-to-image), Understanding (image analysis), Editing (inpainting/outpainting)
- **Local options**: Stable Diffusion, FLUX, LLaVA, MiniCPM-o (via Ollama or ComfyUI)
- **Cloud options**: DALL-E 3, Midjourney, GPT-4o vision, Claude vision, Gemini vision

**Decision tree**:

```text
Need to CREATE images from text?
  → See image-generation.md

Need to UNDERSTAND/ANALYZE existing images?
  → See image-understanding.md

Need to EDIT/MODIFY existing images?
  → See image-editing.md

Need GPU deployment for local models?
  → See tools/infrastructure/cloud-gpu.md
```

<!-- AI-CONTEXT-END -->

## Category Overview

| Category | Use Case | Key Models | Subagent |
|----------|----------|------------|----------|
| **Generation** | Text-to-image, concept art, marketing assets | DALL-E 3, Midjourney, FLUX, Stable Diffusion | `image-generation.md` |
| **Understanding** | Image analysis, captioning, visual Q&A, OCR | GPT-4o, Claude vision, Gemini, LLaVA, Qwen-VL | `image-understanding.md` |
| **Editing** | Inpainting, outpainting, style transfer, upscaling | DALL-E 3 edit, Stable Diffusion inpaint, FLUX fill | `image-editing.md` |

## Model Selection Quick Guide

### By Deployment

| Deployment | Models | Best For |
|------------|--------|----------|
| **Cloud API** | DALL-E 3, GPT-4o vision, Claude vision, Gemini | Quick integration, no GPU needed |
| **Local (Ollama)** | LLaVA, MiniCPM-o, Qwen-VL | Privacy, no API costs, understanding tasks |
| **Local (ComfyUI)** | FLUX, Stable Diffusion XL, ControlNet | Generation, editing, full control |
| **Cloud GPU** | Any model via vLLM/ComfyUI | Scale, large models, batch processing |

### By Task

```text
Product photos / marketing    → DALL-E 3 (cloud) or FLUX (local)
Code screenshot analysis      → Claude vision or GPT-4o vision
Document/receipt OCR          → tools/ocr/glm-ocr.md (dedicated OCR)
GUI automation screenshots    → tools/browser/peekaboo.md (screen capture + vision)
Architectural diagrams        → GPT-4o vision or Gemini (large context)
Image captioning / alt text   → Claude vision or LLaVA (local)
Background removal / editing  → Stable Diffusion inpaint or DALL-E 3 edit
Upscaling / enhancement       → Real-ESRGAN or Topaz (local)
```

## Integration with aidevops

Vision tools integrate with existing subagents:

| Integration | Description |
|-------------|-------------|
| `tools/ocr/glm-ocr.md` | Dedicated OCR (prefer over general vision for text extraction) |
| `tools/browser/peekaboo.md` | Screen capture + vision analysis for GUI automation |
| `tools/video/` | Image-to-video pipelines (Kling, Seedance via Higgsfield) |
| `tools/infrastructure/cloud-gpu.md` | GPU deployment for local vision models |
| `content/` | AI-generated images for content workflows |

## See Also

- `image-generation.md` - Text-to-image model guide
- `image-understanding.md` - Image analysis and multimodal models
- `image-editing.md` - Image modification and enhancement
- `tools/ocr/glm-ocr.md` - Dedicated OCR (text extraction from images)
- `tools/browser/peekaboo.md` - Screen capture with AI vision
- `tools/infrastructure/cloud-gpu.md` - GPU deployment for local models

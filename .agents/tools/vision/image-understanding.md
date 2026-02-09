---
description: "Image understanding - multimodal vision models for analysing and describing images"
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

# Image Understanding

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Analyse, describe, and extract information from images using vision-capable AI models
- **Cloud**: GPT-4o vision, Claude vision (Sonnet/Opus), Gemini 2.5 Pro/Flash
- **Local**: LLaVA, MiniCPM-o, Qwen-VL, InternVL (via Ollama)
- **Dedicated OCR**: `tools/ocr/glm-ocr.md` (prefer for pure text extraction)

**When to use**: Analysing screenshots, describing images for alt text, visual Q&A, diagram interpretation, UI review, accessibility audits, or any task requiring understanding of image content.

**Quick start** (cloud):

```bash
# GPT-4o vision via OpenAI API
curl https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "Describe this image in detail"},
        {"type": "image_url", "image_url": {"url": "https://example.com/image.jpg"}}
      ]
    }]
  }'
```

**Quick start** (local):

```bash
# LLaVA via Ollama (no API key needed)
ollama pull llava
ollama run llava "Describe this image" --images /path/to/image.png
```

<!-- AI-CONTEXT-END -->

## Model Comparison

| Model | Provider | Context | Speed | Cost | Local | Best For |
|-------|----------|---------|-------|------|-------|----------|
| **GPT-4o** | OpenAI | 128K | Fast | $2.50/$10 per 1M tokens | No | General analysis, reasoning |
| **Claude Sonnet** | Anthropic | 200K | Fast | $3/$15 per 1M tokens | No | Nuanced descriptions, code review |
| **Claude Opus** | Anthropic | 200K | Medium | $15/$75 per 1M tokens | No | Complex reasoning about images |
| **Gemini 2.5 Pro** | Google | 1M | Fast | $1.25/$10 per 1M tokens | No | Large images, long documents |
| **Gemini 2.5 Flash** | Google | 1M | Very fast | $0.15/$0.60 per 1M tokens | No | Fast analysis, cost-effective |
| **LLaVA** | Open source | 4K | Medium | Free | Yes | General vision, ~4GB VRAM |
| **MiniCPM-o** | OpenBMB | 8K | Fast | Free | Yes | Efficient local vision, ~4GB |
| **Qwen-VL** | Alibaba | 32K | Medium | Free | Yes | Multilingual, detailed, ~8GB |
| **InternVL 2.5** | Shanghai AI Lab | 8K | Medium | Free | Yes | Strong reasoning, ~8GB |

### Choosing a Model

```text
Need best accuracy?               → GPT-4o or Claude Opus
Need cost-effective cloud?         → Gemini 2.5 Flash
Need large image/document?         → Gemini 2.5 Pro (1M context)
Need nuanced text descriptions?    → Claude Sonnet
Need fully local/private?          → LLaVA or MiniCPM-o (Ollama)
Need multilingual understanding?   → Qwen-VL
Need pure text extraction (OCR)?   → tools/ocr/glm-ocr.md (dedicated)
Need screen capture + analysis?    → tools/browser/peekaboo.md
```

## Cloud APIs

### OpenAI (GPT-4o Vision)

```bash
# Analyse image from URL
curl https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "What UI issues do you see in this screenshot?"},
        {"type": "image_url", "image_url": {"url": "https://example.com/screenshot.png"}}
      ]
    }],
    "max_tokens": 1000
  }'

# Analyse local image (base64)
base64 -i screenshot.png | \
  jq -Rs '{model: "gpt-4o", messages: [{role: "user", content: [{type: "text", text: "Describe this"}, {type: "image_url", image_url: {url: ("data:image/png;base64," + .)}}]}]}' | \
  curl -s https://api.openai.com/v1/chat/completions \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @-
```

**Image token costs**: Images are resized and tiled. A 1024x1024 image uses ~765 tokens. Larger images use more tiles. Use `detail: "low"` for cheaper analysis (~85 tokens per image).

### Anthropic (Claude Vision)

```bash
# Claude vision via Messages API
curl https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1024,
    "messages": [{
      "role": "user",
      "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "<base64-data>"}},
        {"type": "text", "text": "Describe the architecture shown in this diagram"}
      ]
    }]
  }'
```

**Supported formats**: JPEG, PNG, GIF, WebP. Max 5MB per image (API), 10MB (Claude.ai).

### Google (Gemini Vision)

```bash
# Gemini via Google AI Studio API
curl "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GOOGLE_AI_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{
      "parts": [
        {"text": "Analyse this chart and summarise the key trends"},
        {"inline_data": {"mime_type": "image/png", "data": "<base64-data>"}}
      ]
    }]
  }'
```

**Advantage**: 1M token context allows analysing very large images or multiple images in a single request.

## Local Models (Ollama)

### Setup

```bash
# Install Ollama
brew install ollama

# Pull vision models
ollama pull llava           # General vision (~4GB)
ollama pull minicpm-v       # Efficient vision (~4GB)
ollama pull qwen2-vl        # Multilingual vision (~8GB)
```

### Usage

```bash
# Basic image analysis
ollama run llava "What objects are in this image?" --images photo.jpg

# Detailed description for alt text
ollama run llava "Write a detailed alt text description for accessibility" --images hero-image.png

# UI review
ollama run minicpm-v "List all UI elements and their approximate positions" --images screenshot.png

# Diagram interpretation
ollama run qwen2-vl "Explain the architecture shown in this diagram" --images architecture.png
```

### Ollama API (Programmatic)

```bash
# Via Ollama REST API
curl http://localhost:11434/api/generate \
  -d '{
    "model": "llava",
    "prompt": "Describe this image",
    "images": ["<base64-encoded-image>"]
  }'
```

## Common Use Cases

### Alt Text Generation

```bash
# Generate accessible alt text for web images
ollama run llava "Write a concise, descriptive alt text for this image suitable for screen readers. Focus on the key visual content and purpose." --images hero.jpg
```

### UI/UX Review

```bash
# Analyse a screenshot for UI issues
ollama run minicpm-v "Review this UI screenshot. Identify: 1) Alignment issues 2) Contrast problems 3) Missing elements 4) Accessibility concerns" --images app-screenshot.png
```

### Diagram to Code

```bash
# Convert a wireframe/diagram to code description
ollama run qwen2-vl "Describe this wireframe as a structured layout specification I can implement in HTML/CSS. List each component, its position, and approximate dimensions." --images wireframe.png
```

### Batch Image Analysis

```bash
#!/usr/bin/env bash
# Analyse all images in a directory
set -euo pipefail

local dir="${1:-.}"
local model="${2:-llava}"
local prompt="${3:-Describe this image in one sentence}"

for img in "$dir"/*.{jpg,png,webp}; do
  [ -f "$img" ] || continue
  echo "=== $(basename "$img") ==="
  ollama run "$model" "$prompt" --images "$img"
  echo
done
```

### Compare with Peekaboo

For screen capture + vision analysis in a single command:

```bash
# Capture and analyse (uses Peekaboo's built-in vision)
peekaboo image --mode screen --analyze "What application is shown and what is the user doing?" --model ollama/llava

# Capture specific window
peekaboo image --mode window --app Safari --analyze "Summarise the web page content" --model openai/gpt-4o
```

See `tools/browser/peekaboo.md` for full Peekaboo integration.

## Token Cost Estimation

| Provider | Low Detail | High Detail (1024x1024) | High Detail (2048x2048) |
|----------|-----------|------------------------|------------------------|
| OpenAI | ~85 tokens | ~765 tokens | ~1,105 tokens |
| Anthropic | ~1,000 tokens | ~1,600 tokens | ~3,200 tokens |
| Google | ~258 tokens | ~258 tokens | ~516 tokens |
| Local (Ollama) | Free | Free | Free |

**Cost tip**: Use `detail: "low"` in OpenAI API for quick classification tasks. Use high detail only when fine visual details matter.

## See Also

- `overview.md` - Vision AI category overview
- `image-generation.md` - Create new images from text
- `image-editing.md` - Modify existing images
- `tools/ocr/glm-ocr.md` - Dedicated OCR for text extraction
- `tools/browser/peekaboo.md` - Screen capture + vision analysis
- `tools/infrastructure/cloud-gpu.md` - GPU deployment for local models

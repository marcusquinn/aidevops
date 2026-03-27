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

**Purpose**: Analyse, describe, and extract information from images using vision-capable AI models.
**When to use**: Screenshots, alt text, visual Q&A, diagram interpretation, UI review, accessibility audits.
**Dedicated OCR**: `tools/ocr/glm-ocr.md` | **Screen capture**: `tools/browser/peekaboo.md`

<!-- AI-CONTEXT-END -->

## Model Selection

| Model | Provider | Context | Cost (in/out per 1M) | Local | Best For |
|-------|----------|---------|----------------------|-------|----------|
| **GPT-4o** | OpenAI | 128K | $2.50/$10 | No | General analysis, reasoning |
| **Claude Sonnet** | Anthropic | 200K | $3/$15 | No | Nuanced descriptions, code review |
| **Claude Opus** | Anthropic | 200K | $15/$75 | No | Complex reasoning |
| **Gemini 2.5 Pro** | Google | 1M | $1.25/$10 | No | Large images, long documents |
| **Gemini 2.5 Flash** | Google | 1M | $0.15/$0.60 | No | Fast, cost-effective |
| **LLaVA** | Open source | 4K | Free | Yes | General vision, ~4GB VRAM |
| **MiniCPM-o** | OpenBMB | 8K | Free | Yes | Efficient local, ~4GB |
| **Qwen-VL** | Alibaba | 32K | Free | Yes | Multilingual, ~8GB |
| **InternVL 2.5** | Shanghai AI Lab | 8K | Free | Yes | Strong reasoning, ~8GB |

| Need | Use |
|------|-----|
| Best accuracy | GPT-4o or Claude Opus |
| Cost-effective cloud | Gemini 2.5 Flash |
| Large image/document | Gemini 2.5 Pro (1M context) |
| Nuanced text descriptions | Claude Sonnet |
| Fully local/private | LLaVA or MiniCPM-o (Ollama) |
| Multilingual | Qwen-VL |
| Pure text extraction | `tools/ocr/glm-ocr.md` |
| Screen capture + analysis | `tools/browser/peekaboo.md` |

## Cloud APIs

### OpenAI (GPT-4o Vision)

```bash
# URL image
curl https://api.openai.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":[{"type":"text","text":"Describe this image"},{"type":"image_url","image_url":{"url":"https://example.com/image.jpg"}}]}],"max_tokens":1000}'

# Local image (base64)
base64 -i screenshot.png | \
  jq -Rs '{model:"gpt-4o",messages:[{role:"user",content:[{type:"text",text:"Describe this"},{type:"image_url",image_url:{url:("data:image/png;base64,"+.)}}]}]}' | \
  curl -s https://api.openai.com/v1/chat/completions -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" -d @-
```

**Token costs**: 1024×1024 ≈ 765 tokens. Use `detail: "low"` (~85 tokens) for classification. See [OpenAI vision docs](https://platform.openai.com/docs/guides/vision) for per-model limits.

### Anthropic (Claude Vision)

```bash
curl https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":1024,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"<base64-data>"}},{"type":"text","text":"Describe this"}]}]}'
```

**Limits**: JPEG, PNG, GIF, WebP. Max 5MB (API) / 10MB (Claude.ai). Hard limit: 8000×8000 px. Long edge >1568 px is auto-downscaled — resize first for optimal latency:

```bash
sips --resampleHeightWidthMax 1568 input.png --out output.png   # macOS built-in
magick input.png -resize '1568x1568>' output.png                # ImageMagick ('>' = only shrink)
```

`browser-qa-helper.sh` applies this resize automatically.

### Google (Gemini Vision)

```bash
curl "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$GOOGLE_AI_KEY" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"parts":[{"text":"Analyse this chart"},{"inline_data":{"mime_type":"image/png","data":"<base64-data>"}}]}]}'
```

**Advantage**: 1M token context for very large images or multiple images per request.

## Local Models (Ollama)

```bash
# Setup
brew install ollama
ollama pull llava        # General vision (~4GB)
ollama pull minicpm-v    # Efficient local (~4GB)
ollama pull qwen2-vl     # Multilingual (~8GB)

# CLI usage
ollama run llava "Describe this image" --images photo.jpg
ollama run minicpm-v "List UI elements and positions" --images screenshot.png
ollama run qwen2-vl "Explain this architecture diagram" --images diagram.png

# REST API
curl http://localhost:11434/api/generate \
  -d '{"model":"llava","prompt":"Describe this image","images":["<base64>"]}'
```

## Common Use Cases

```bash
# Alt text for accessibility
ollama run llava "Write concise alt text for screen readers. Focus on key visual content and purpose." --images hero.jpg

# UI/UX review
ollama run minicpm-v "Review this UI: 1) Alignment 2) Contrast 3) Missing elements 4) Accessibility" --images screenshot.png

# Wireframe to layout spec
ollama run qwen2-vl "Describe as HTML/CSS layout spec: components, positions, dimensions." --images wireframe.png

# Batch analysis
for img in dir/*.{jpg,png,webp}; do
  [ -f "$img" ] || continue
  echo "=== $(basename "$img") ===" && ollama run llava "Describe in one sentence" --images "$img"
done

# Screen capture + analysis (Peekaboo)
peekaboo image --mode screen --analyze "What is shown?" --model ollama/llava
peekaboo image --mode window --app Safari --analyze "Summarise page content" --model openai/gpt-4o
```

## Token Cost Reference

| Provider | Low detail | 1024×1024 | 2048×2048 |
|----------|-----------|-----------|-----------|
| OpenAI | ~85 | ~765 | ~1,105 |
| Anthropic | ~1,000 | ~1,600 | ~3,200 |
| Google | ~258 | ~258 | ~516 |
| Local | Free | Free | Free |

## See Also

- `overview.md` — Vision AI category overview
- `image-generation.md` — Create images from text
- `image-editing.md` — Modify existing images
- `tools/ocr/glm-ocr.md` — Dedicated OCR
- `tools/browser/peekaboo.md` — Screen capture + vision
- `tools/infrastructure/cloud-gpu.md` — GPU deployment for local models

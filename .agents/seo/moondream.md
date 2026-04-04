---
description: Moondream AI vision model for image analysis, captioning, and object detection
mode: subagent
tools:
  read: true
  write: true
  bash: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Moondream AI Vision

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Image analysis via Moondream vision model for SEO metadata generation
- **Model**: Moondream 3 Preview (9B total params, 2B active, 32k context, MoE)
- **API**: `https://api.moondream.ai/v1/` — auth: `X-Moondream-Auth` header
- **SDK**: Python (`pip install moondream`), Node.js (`npm install moondream`)
- **Local**: Moondream Station (free, offline, CPU/GPU) — [moondream.ai/station](https://moondream.ai/station)
- **Pricing**: $0.30/M input tokens, $2.50/M output tokens, $5/mo free credits
- **Credential**: `aidevops secret set MOONDREAM_API_KEY` or `~/.config/aidevops/credentials.sh`
- **Skills**: Query (VQA), Caption, Detect (bounding boxes), Point (coordinates), Segment (SVG masks)

<!-- AI-CONTEXT-END -->

## API Reference

All endpoints: POST JSON to `https://api.moondream.ai/v1/{endpoint}`. Headers: `Content-Type: application/json`, `X-Moondream-Auth: $MOONDREAM_API_KEY`. Image input: URL (`"image_url": "https://..."`), Base64 (`"image_url": "data:image/jpeg;base64,..."`), local file (SDK only).

| Endpoint | Purpose | Key params | Response |
|----------|---------|------------|----------|
| `/caption` | Image descriptions (SEO alt text) | `length`: `"short"`, `"normal"`, `"long"` | `{"caption": "...", "metrics": {...}}` |
| `/query` | Visual QA (keywords, filenames, tags) | `question`: free-text | `{"answer": "..."}` |
| `/detect` | Object detection (bounding boxes) | `object`: target label | `{"objects": [{"x_min", "y_min", "x_max", "y_max"}]}` |
| `/point` | Object center coordinates | `object`: target label | Center point per matched object |
| `/segment` | SVG path masks (background removal) | `object`: target label | SVG path masks |

```bash
# Example: caption endpoint (other endpoints follow same pattern)
curl -X POST https://api.moondream.ai/v1/caption \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{"image_url": "https://example.com/image.jpg", "length": "normal", "stream": false}'
```

## SEO Prompt Templates (`/query` endpoint)

| Use case | Question prompt |
|----------|----------------|
| **Alt text** | `Describe this image in one sentence for use as alt text on a webpage. Be specific about the subject, action, and setting. Do not start with "A photo of" or "An image of".` |
| **SEO filename** | `Suggest a descriptive, SEO-friendly filename for this image using lowercase words separated by hyphens. No file extension. Example format: golden-retriever-sitting-wooden-deck` |
| **Keyword/tags** | `List 5-10 relevant keywords or tags for this image, separated by commas. Include the main subject, setting, colors, and mood.` |

## SDK Usage

### Python

```python
import moondream as md
from PIL import Image

model = md.vl(api_key="YOUR_API_KEY")  # Local: md.vl(api_url="http://localhost:2020")
image = Image.open("product.jpg")

caption = model.caption(image, length="normal")["caption"]
answer = model.query(image, "Suggest an SEO-friendly filename using hyphens")["answer"]
objects = model.detect(image, "product")["objects"]
```

### Node.js

```javascript
import { vl } from 'moondream';
import fs from 'fs';

const model = new vl({ apiKey: 'YOUR_API_KEY' });
const image = fs.readFileSync('product.jpg');

const caption = (await model.caption({ image, length: 'normal' })).caption;
const answer = (await model.query({ image, question: 'List 5-10 SEO tags, comma-separated' })).answer;
```

## Rate Limits & Benchmarks

**Rate limits**: Free 2 RPS ($5/mo free credits), Paid 10+ RPS (pay-as-you-go).

| Task | Moondream 3 | GPT 5 | Gemini 2.5 Flash | Claude 4 Sonnet |
|------|-------------|-------|-------------------|-----------------|
| Object Detection (RefCOCO) | **91.1** | 57.2 | 75.8 | 30.1 |
| Counting (CountbenchQA) | **93.2** | 89.3 | 81.2 | 90.1 |
| Document (ChartQA) | **86.6** | 85 | 79.5 | 74.3 |
| Hallucination (POPE) | **89.0** | 88.4 | 88.1 | 84.6 |

## Related

- `seo/image-seo.md` - Image SEO orchestrator (uses Moondream for analysis)
- `seo/upscale.md` - Image upscaling services
- `seo/debug-opengraph.md` - Open Graph image validation
- `seo/site-crawler.md` - Crawl output includes image alt text audit

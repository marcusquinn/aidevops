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

# Moondream AI Vision

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Analyze images using Moondream vision model for SEO metadata generation
- **Model**: Moondream 3 Preview (9B total params, 2B active, 32k context, MoE)
- **API**: `https://api.moondream.ai/v1/` with `X-Moondream-Auth` header
- **SDK**: Python (`pip install moondream`), Node.js (`npm install moondream`)
- **Local**: Moondream Station (free, offline, CPU/GPU)
- **Pricing**: $0.30/M input tokens, $2.50/M output tokens, $5/mo free credits
- **Credential**: `aidevops secret set MOONDREAM_API_KEY` or add to `~/.config/aidevops/credentials.sh`

**Skills**: Query (VQA), Caption, Detect (bounding boxes), Point (coordinates), Segment (SVG masks)

<!-- AI-CONTEXT-END -->

## API Endpoints

Base URL: `https://api.moondream.ai/v1/`

### Caption (Primary for SEO)

Generate natural language descriptions of images. Use for alt text and content descriptions.

```bash
curl -X POST https://api.moondream.ai/v1/caption \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/image.jpg",
    "length": "normal",
    "stream": false
  }'
```

Response:

```json
{
  "caption": "A golden retriever sitting on a wooden deck...",
  "metrics": {
    "input_tokens": 735,
    "output_tokens": 45,
    "prefill_time_ms": 43.5,
    "decode_time_ms": 415.3
  },
  "finish_reason": "stop"
}
```

Caption lengths: `"short"`, `"normal"`, `"long"`.

### Query (VQA - for SEO metadata)

Ask specific questions about images to extract SEO-relevant information.

```bash
curl -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/image.jpg",
    "question": "What objects, colors, and activities are shown in this image? List keywords suitable for SEO tags."
  }'
```

Response:

```json
{
  "request_id": "...",
  "answer": "The image shows a golden retriever dog sitting on a wooden deck. Keywords: golden retriever, dog, pet, wooden deck, outdoor, sunny day, animal."
}
```

### Detect (Object Detection)

Identify and locate objects with bounding boxes.

```bash
curl -X POST https://api.moondream.ai/v1/detect \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/image.jpg",
    "object": "dog"
  }'
```

Response:

```json
{
  "objects": [
    { "x_min": 0.2, "y_min": 0.3, "x_max": 0.6, "y_max": 0.8 }
  ]
}
```

### Point (Object Pointing)

Get precise center coordinates for objects.

```bash
curl -X POST https://api.moondream.ai/v1/point \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/image.jpg",
    "object": "dog"
  }'
```

### Segment (Image Segmentation)

Generate SVG path masks for objects. Useful for background removal before publishing.

```bash
curl -X POST https://api.moondream.ai/v1/segment \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/image.jpg",
    "object": "product"
  }'
```

## Image Input Formats

Moondream accepts images via:

- **URL**: `"image_url": "https://example.com/image.jpg"`
- **Base64**: `"image_url": "data:image/jpeg;base64,/9j/..."`
- **Local file** (SDK only): `Image.open("path/to/image.jpg")`

## SEO-Specific Prompts

### Alt Text Generation

```bash
# Concise, descriptive alt text
curl -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/product.jpg",
    "question": "Describe this image in one sentence for use as alt text on a webpage. Be specific about the subject, action, and setting. Do not start with \"A photo of\" or \"An image of\"."
  }'
```

### SEO Filename Suggestion

```bash
# Generate SEO-friendly filename
curl -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/IMG_4521.jpg",
    "question": "Suggest a descriptive, SEO-friendly filename for this image using lowercase words separated by hyphens. No file extension. Example format: golden-retriever-sitting-wooden-deck"
  }'
```

### Keyword/Tag Extraction

```bash
# Extract tags for image metadata
curl -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d '{
    "image_url": "https://example.com/image.jpg",
    "question": "List 5-10 relevant keywords or tags for this image, separated by commas. Include the main subject, setting, colors, and mood."
  }'
```

## SDK Usage

### Python

```python
import moondream as md
from PIL import Image

model = md.vl(api_key="YOUR_API_KEY")
image = Image.open("product.jpg")

# Caption for alt text
caption = model.caption(image, length="normal")
print(caption["caption"])

# Query for SEO filename
result = model.query(image, "Suggest an SEO-friendly filename using hyphens")
print(result["answer"])

# Detect objects
objects = model.detect(image, "product")
print(objects["objects"])
```

### Node.js

```javascript
import { vl } from 'moondream';
import fs from 'fs';

const model = new vl({ apiKey: 'YOUR_API_KEY' });
const image = fs.readFileSync('product.jpg');

// Caption for alt text
const caption = await model.caption({ image, length: 'normal' });
console.log(caption.caption);

// Query for SEO tags
const result = await model.query({
  image,
  question: 'List 5-10 SEO tags for this image, comma-separated'
});
console.log(result.answer);
```

## Running Locally

Moondream Station provides free local inference (no API key needed):

1. Download from [moondream.ai/station](https://moondream.ai/station)
2. Install and launch (macOS/Linux)
3. Point SDK to local endpoint instead of cloud

```python
# Local inference (no API key)
model = md.vl(api_url="http://localhost:2020")
```

## Rate Limits

| Tier | Requests/sec | Notes |
|------|-------------|-------|
| Free | 2 RPS | $5/mo free credits |
| Paid | 10+ RPS | Pay-as-you-go |

## Benchmarks (Moondream 3 Preview)

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

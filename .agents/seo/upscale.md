---
description: Image upscaling services for quality enhancement before publishing
mode: subagent
tools:
  read: true
  write: true
  bash: true
  webfetch: true
  task: true
---

# Image Upscaling

<!-- AI-CONTEXT-START -->

**Decision tree**: Local CLI for bulk/privacy → Replicate for quality/convenience → Cloudflare for CDN-integrated

**Minimum targets**: 1200px wide (social sharing), 800px (blog content), 2x for retina

<!-- AI-CONTEXT-END -->

## Providers

### 1. Real-ESRGAN (Local — Bulk/Privacy)

```bash
brew install real-esrgan  # macOS; or pip install realesrgan

# Single image (4x default)
realesrgan-ncnn-vulkan -i input.jpg -o output.jpg
# Specific scale
realesrgan-ncnn-vulkan -i input.jpg -o output.jpg -s 2
# Batch directory
realesrgan-ncnn-vulkan -i /path/to/images/ -o /path/to/output/
# Specify model
realesrgan-ncnn-vulkan -i input.jpg -o output.jpg -n realesrgan-x4plus
```

| Model | Best for | Scale |
|-------|----------|-------|
| `realesrgan-x4plus` | General photos (default) | 4x |
| `realesrgan-x4plus-anime` | Illustrations, anime | 4x |
| `realesr-animevideov3` | Video frames | 4x |

### 2. Replicate API (Cloud — Best Quality)

```bash
aidevops secret set REPLICATE_API_TOKEN

curl -s -X POST https://api.replicate.com/v1/predictions \
  -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "version": "42fed1c4974146d4d2414e2be2c5277c7fcf05fcc3a73abf41610695738c1d7b",
    "input": {"image": "https://example.com/low-res-image.jpg", "scale": 4, "face_enhance": true}
  }'

# Poll result
curl -s "https://api.replicate.com/v1/predictions/$PREDICTION_ID" \
  -H "Authorization: Bearer $REPLICATE_API_TOKEN" | jq '.output'
```

| Model | Strengths | Cost |
|-------|-----------|------|
| `nightmareai/real-esrgan` | General purpose, face enhance | ~$0.002/image |
| `cjwbw/real-esrgan` | Fast, reliable | ~$0.002/image |
| `philz1337x/clarity-upscaler` | Creative upscaling | ~$0.01/image |
| `tencentarc/gfpgan` | Face restoration | ~$0.003/image |

### 3. Cloudflare Images (CDN-Integrated)

Resize/optimize on-the-fly (requires Cloudflare Pro+). Not AI upscaling — handles format conversion and responsive variants.

```bash
# URL-based resizing
# https://example.com/cdn-cgi/image/width=1200,format=webp/image.jpg

# Upload via API
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/images/v1" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -F "file=@image.jpg"
```

### 4. Sharp (Node.js — Format Conversion)

Not upscaling. Use for WebP/AVIF conversion and responsive variants.

```javascript
import sharp from 'sharp';  // npm install sharp

await sharp('input.jpg').resize(1200, null, { withoutEnlargement: true }).webp({ quality: 80 }).toFile('output.webp');

for (const width of [400, 800, 1200, 1600]) {
  await sharp('input.jpg').resize(width).webp({ quality: 80 }).toFile(`output-${width}w.webp`);
}
```

## When to Upscale

| Scenario | Action | Tool |
|----------|--------|------|
| Image < 1200px wide | Upscale to 1200px+ | Real-ESRGAN |
| Blurry product photo | Upscale + enhance | Replicate (face_enhance) |
| Legacy content migration | Batch upscale all | Real-ESRGAN CLI |
| Social sharing (OG image) | Ensure 1200x630+ | Real-ESRGAN or resize |
| Retina display support | Generate 2x variant | Sharp resize |
| Wrong format (BMP, TIFF) | Convert to WebP | Sharp |

## Pipeline

```text
1. Analyze (Moondream) -> Get content description
2. Upscale (if needed) -> Ensure minimum dimensions
3. Convert format     -> WebP (primary), JPEG (fallback)
4. Compress           -> Target < 200KB for web
5. Generate variants  -> 400w, 800w, 1200w, 1600w
6. Rename             -> SEO-friendly filename
7. Add metadata       -> Alt text, title, IPTC keywords
8. Validate           -> Check OG requirements met
```

## Size Targets

| Use Case | Min Width | Format | Max File Size |
|----------|-----------|--------|---------------|
| Blog content | 800px | WebP | 150KB |
| Product image | 1000px | WebP | 200KB |
| Hero/banner | 1600px | WebP | 300KB |
| OG/social share | 1200px | JPEG/PNG | 300KB |
| Thumbnail | 400px | WebP | 50KB |
| Favicon | 512px | PNG | 20KB |

## Related

- `seo/image-seo.md` - Image SEO orchestrator (coordinates upscaling)
- `seo/moondream.md` - AI vision analysis (pre-upscale content check)
- `seo/debug-opengraph.md` - Validate OG image dimensions
- `tools/browser/pagespeed.md` - Image optimization scoring

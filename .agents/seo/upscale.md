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

## Quick Reference

- **Purpose**: Upscale low-resolution images for web publishing and social sharing
- **When to use**: Images below 1200px wide, blurry product photos, legacy content migration
- **Providers**: Replicate (Real-ESRGAN), Cloudflare Images, local (Real-ESRGAN CLI)
- **Minimum targets**: 1200px wide (social sharing), 800px (blog content), 2x for retina

**Decision tree**: Local CLI for bulk/privacy -> Replicate for quality/convenience -> Cloudflare for CDN-integrated

<!-- AI-CONTEXT-END -->

## Upscaling Providers

### 1. Real-ESRGAN (Local - Recommended for Bulk)

Free, open-source, runs locally. Best for batch processing and privacy-sensitive images.

**Install:**

```bash
# macOS (Homebrew)
brew install real-esrgan

# Or download binary from GitHub
# https://github.com/xinntao/Real-ESRGAN/releases

# Python (pip)
pip install realesrgan
```

**Usage:**

```bash
# Upscale single image (4x default)
realesrgan-ncnn-vulkan -i input.jpg -o output.jpg

# Upscale with specific scale factor
realesrgan-ncnn-vulkan -i input.jpg -o output.jpg -s 2

# Batch upscale directory
realesrgan-ncnn-vulkan -i /path/to/images/ -o /path/to/output/

# Specify model (anime vs photo)
realesrgan-ncnn-vulkan -i input.jpg -o output.jpg -n realesrgan-x4plus
```

**Models:**

| Model | Best for | Scale |
|-------|----------|-------|
| `realesrgan-x4plus` | General photos (default) | 4x |
| `realesrgan-x4plus-anime` | Illustrations, anime | 4x |
| `realesr-animevideov3` | Video frames | 4x |

### 2. Replicate API (Cloud - Best Quality)

Pay-per-use cloud API. Multiple model options, no local GPU needed.

**Setup:**

```bash
aidevops secret set REPLICATE_API_TOKEN
# Or: export REPLICATE_API_TOKEN="r8_..."
```

**Real-ESRGAN via Replicate:**

```bash
curl -s -X POST https://api.replicate.com/v1/predictions \
  -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "version": "42fed1c4974146d4d2414e2be2c5277c7fcf05fcc3a73abf41610695738c1d7b",
    "input": {
      "image": "https://example.com/low-res-image.jpg",
      "scale": 4,
      "face_enhance": true
    }
  }'
```

**Check prediction status:**

```bash
curl -s "https://api.replicate.com/v1/predictions/$PREDICTION_ID" \
  -H "Authorization: Bearer $REPLICATE_API_TOKEN" \
  | jq '.output'
```

**Alternative models on Replicate:**

| Model | Strengths | Cost |
|-------|-----------|------|
| `nightmareai/real-esrgan` | General purpose, face enhance | ~$0.002/image |
| `cjwbw/real-esrgan` | Fast, reliable | ~$0.002/image |
| `philz1337x/clarity-upscaler` | Creative upscaling | ~$0.01/image |
| `tencentarc/gfpgan` | Face restoration | ~$0.003/image |

### 3. Cloudflare Images (CDN-Integrated)

Resize and optimize on-the-fly via Cloudflare. No upscaling per se, but handles format conversion and responsive variants.

```bash
# Cloudflare Image Resizing (requires Cloudflare Pro+)
# Original: https://example.com/image.jpg
# Resized:  https://example.com/cdn-cgi/image/width=1200,format=webp/image.jpg

# Variants via Cloudflare Images API
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/images/v1" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -F "file=@image.jpg" \
  -F "metadata={\"key\":\"value\"}"
```

### 4. Sharp (Node.js - Format Conversion)

Not upscaling, but essential for format optimization (WebP/AVIF conversion, compression).

```bash
npm install sharp
```

```javascript
import sharp from 'sharp';

// Convert to WebP with quality optimization
await sharp('input.jpg')
  .resize(1200, null, { withoutEnlargement: true })
  .webp({ quality: 80 })
  .toFile('output.webp');

// Generate responsive variants
for (const width of [400, 800, 1200, 1600]) {
  await sharp('input.jpg')
    .resize(width)
    .webp({ quality: 80 })
    .toFile(`output-${width}w.webp`);
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

## Image Optimization Pipeline

Complete pipeline from raw image to web-ready:

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

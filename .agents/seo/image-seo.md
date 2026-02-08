---
description: Image SEO orchestrator - AI-powered filename, alt text, and tag generation
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
---

# Image SEO Enhancement

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Optimize images for search engines using AI vision analysis
- **Coordinates**: `seo/moondream.md` (vision analysis) + `seo/upscale.md` (quality enhancement)
- **Capabilities**: SEO filename generation, alt text, keyword tags, WCAG-compliant descriptions
- **Input**: Image URL, local file path, or base64
- **Output**: Optimized filename, alt text, tags, and optional upscaled image

**Workflow**: Analyze image (Moondream) -> Generate SEO metadata -> Optionally upscale -> Apply to CMS/HTML

<!-- AI-CONTEXT-END -->

## Image SEO Workflow

### 1. Single Image Optimization

Given an image, generate all SEO metadata in one pass:

```bash
# Step 1: Get caption for alt text
CAPTION=$(curl -s -X POST https://api.moondream.ai/v1/caption \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\", \"length\": \"normal\"}" \
  | jq -r '.caption')

# Step 2: Get SEO filename suggestion
FILENAME=$(curl -s -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{
    \"image_url\": \"$IMAGE_URL\",
    \"question\": \"Suggest a descriptive SEO-friendly filename using lowercase hyphenated words. No extension. Example: golden-retriever-wooden-deck\"
  }" | jq -r '.answer')

# Step 3: Get keyword tags
TAGS=$(curl -s -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{
    \"image_url\": \"$IMAGE_URL\",
    \"question\": \"List 5-10 relevant SEO keywords for this image, comma-separated. Include subject, setting, colors, mood.\"
  }" | jq -r '.answer')

echo "Alt text: $CAPTION"
echo "Filename: $FILENAME"
echo "Tags: $TAGS"
```

### 2. Batch Image Optimization

Process multiple images from a directory or URL list:

```bash
# Process all images in a directory
for img in /path/to/images/*.{jpg,png,webp}; do
  echo "Processing: $img"

  # Base64 encode for API
  B64=$(base64 -i "$img" | tr -d '\n')
  IMAGE_DATA="data:image/jpeg;base64,$B64"

  # Get alt text
  ALT=$(curl -s -X POST https://api.moondream.ai/v1/caption \
    -H 'Content-Type: application/json' \
    -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
    -d "{\"image_url\": \"$IMAGE_DATA\", \"length\": \"normal\"}" \
    | jq -r '.caption')

  # Get filename
  NAME=$(curl -s -X POST https://api.moondream.ai/v1/query \
    -H 'Content-Type: application/json' \
    -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
    -d "{
      \"image_url\": \"$IMAGE_DATA\",
      \"question\": \"Suggest a descriptive SEO-friendly filename using lowercase hyphenated words. No extension.\"
    }" | jq -r '.answer')

  EXT="${img##*.}"
  echo "$img -> $NAME.$EXT | Alt: $ALT"
done
```

### 3. WordPress Integration

Update image metadata in WordPress via WP-CLI or REST API:

```bash
# Via WP-CLI (SSH)
wp media update $ATTACHMENT_ID --alt="$ALT_TEXT" --title="$SEO_TITLE"

# Via REST API
curl -X POST "https://example.com/wp-json/wp/v2/media/$ATTACHMENT_ID" \
  -H "Authorization: Bearer $WP_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{
    \"alt_text\": \"$ALT_TEXT\",
    \"title\": { \"raw\": \"$SEO_TITLE\" },
    \"caption\": { \"raw\": \"$CAPTION\" }
  }"
```

## Alt Text Best Practices (WCAG 2.1)

When generating alt text, the AI output should follow these guidelines:

| Rule | Example |
|------|---------|
| Be specific and concise | "Golden retriever sitting on wooden deck" not "A dog" |
| Describe the content, not the format | Not "Photo of..." or "Image showing..." |
| Include relevant context | "CEO Jane Smith speaking at annual conference" |
| Skip decorative images | Use `alt=""` for purely decorative images |
| Max ~125 characters | Screen readers may truncate longer text |
| Include keywords naturally | Don't keyword-stuff, but include relevant terms |

### Alt Text Prompt Template

```text
Describe this image in one sentence for use as alt text on a webpage.
Be specific about the subject, action, and setting.
Do not start with "A photo of", "An image of", or "A picture of".
Keep it under 125 characters.
If the image contains text, include the key text content.
```

## SEO Filename Conventions

| Convention | Example |
|------------|---------|
| Lowercase | `golden-retriever.jpg` not `Golden-Retriever.jpg` |
| Hyphens (not underscores) | `red-running-shoes.jpg` not `red_running_shoes.jpg` |
| Descriptive | `nike-air-max-90-white.jpg` not `IMG_4521.jpg` |
| Include primary keyword | `organic-coffee-beans-bag.jpg` |
| No special characters | No spaces, accents, or symbols |
| Reasonable length | 3-6 words, under 60 characters |

### Filename Prompt Template

```text
Suggest a descriptive, SEO-friendly filename for this image.
Use lowercase words separated by hyphens. No file extension.
Include the main subject and one distinguishing detail.
Keep it 3-6 words. Example: golden-retriever-wooden-deck
```

## Image Tag/Keyword Extraction

Tags extracted from images can be used for:

- **WordPress tags/categories**: Auto-categorize media library
- **Schema.org ImageObject**: `keywords` property
- **Open Graph**: `og:image:alt` and related meta
- **Internal search**: Make images findable within CMS
- **Stock photo metadata**: IPTC/XMP keyword fields

### Tag Prompt Template

```text
List 5-10 relevant keywords for this image, comma-separated.
Include: main subject, setting/location type, dominant colors,
mood/atmosphere, and any notable objects or activities.
Order from most to least relevant.
```

## Quality Checks

Before publishing optimized images, verify:

1. **Alt text length**: 5-125 characters (warn if outside range)
2. **Filename format**: Lowercase, hyphens, no special chars
3. **Tag count**: 5-10 tags per image
4. **Image dimensions**: Minimum 1200px wide for social sharing
5. **File size**: Under 200KB for web (consider upscale.md for quality)
6. **Format**: WebP preferred, JPEG fallback, PNG for transparency

## Integration Points

| Component | How it connects |
|-----------|----------------|
| `seo/moondream.md` | Vision API for image analysis |
| `seo/upscale.md` | Quality enhancement before publishing |
| `seo/debug-opengraph.md` | Validate OG image after optimization |
| `seo/site-crawler.md` | Audit existing images for missing alt text |
| `seo/seo-audit-skill.md` | Image optimization checklist |
| `tools/wordpress/wp-dev.md` | WordPress media management |
| `content.md` | Content creation with optimized images |

## Schema.org ImageObject

After generating SEO metadata, apply structured data:

```json
{
  "@type": "ImageObject",
  "contentUrl": "https://example.com/images/golden-retriever-wooden-deck.webp",
  "name": "Golden Retriever on Wooden Deck",
  "description": "A golden retriever sitting on a sunlit wooden deck in a backyard garden",
  "keywords": "golden retriever, dog, wooden deck, backyard, sunny, pet",
  "width": 1200,
  "height": 800,
  "encodingFormat": "image/webp"
}
```

## Related

- `seo/moondream.md` - Moondream AI vision API (analysis engine)
- `seo/upscale.md` - Image upscaling services (quality enhancement)
- `seo/debug-opengraph.md` - Open Graph image validation
- `seo/site-crawler.md` - Crawl output includes image alt text audit
- `seo/seo-audit-skill.md` - Image optimization checklist items
- `seo/schema-validator.md` - Validate ImageObject structured data

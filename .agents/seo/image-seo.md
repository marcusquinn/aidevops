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
- **Purpose**: Optimize images for search engines using AI vision analysis
- **Coordinates**: `seo/moondream.md` (vision) + `seo/upscale.md` (quality)
- **Input**: Image URL, local file path, or base64
- **Output**: Optimized filename, alt text, tags, optional upscaled image
- **Workflow**: Analyze (Moondream) -> Generate SEO metadata -> Optionally upscale -> Apply to CMS/HTML
<!-- AI-CONTEXT-END -->

## Prompt Templates

### Alt Text (WCAG 2.1)

```text
Describe this image in one sentence for use as alt text on a webpage.
Be specific about the subject, action, and setting.
Do not start with "A photo of", "An image of", or "A picture of".
Keep it under 125 characters.
If the image contains text, include the key text content.
```

Rules: Be specific ("Golden retriever sitting on wooden deck" not "A dog"). Describe content, not format. Include relevant context. Use `alt=""` for decorative images. Max ~125 chars. Include keywords naturally without stuffing.

### SEO Filename

```text
Suggest a descriptive, SEO-friendly filename for this image.
Use lowercase words separated by hyphens. No file extension.
Include the main subject and one distinguishing detail.
Keep it 3-6 words. Example: golden-retriever-wooden-deck
```

Rules: Lowercase hyphens only (`red-running-shoes.jpg`). Descriptive (`nike-air-max-90-white.jpg` not `IMG_4521.jpg`). Include primary keyword. No spaces/accents/symbols. 3-6 words, under 60 chars.

### Keyword Tags

```text
List 5-10 relevant keywords for this image, comma-separated.
Include: main subject, setting/location type, dominant colors,
mood/atmosphere, and any notable objects or activities.
Order from most to least relevant.
```

Used for: WordPress tags/categories, Schema.org `ImageObject.keywords`, Open Graph `og:image:alt`, CMS internal search, IPTC/XMP metadata.

## Single Image Optimization

```bash
CAPTION=$(curl -s -X POST https://api.moondream.ai/v1/caption \
  -H 'Content-Type: application/json' -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\", \"length\": \"normal\"}" | jq -r '.caption')

FILENAME=$(curl -s -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\", \"question\": \"Suggest a descriptive SEO-friendly filename using lowercase hyphenated words. No extension.\"}" \
  | jq -r '.answer')

# Keyword tags: same /v1/query endpoint with tag prompt template above
```

## Batch Processing

Same API calls, wrapped in a loop with base64 encoding for local files:

```bash
for img in /path/to/images/*.{jpg,png,webp}; do
  EXT="${img##*.}"
  case "$EXT" in jpg) MIME="image/jpeg" ;; *) MIME="image/$EXT" ;; esac
  B64=$(base64 -i "$img" | tr -d '\n')
  IMAGE_DATA="data:${MIME};base64,$B64"
  # Use $IMAGE_DATA in place of $IMAGE_URL in the API calls above
done
```

## WordPress Integration

```bash
# Via WP-CLI
wp media update $ATTACHMENT_ID --alt="$ALT_TEXT" --title="$SEO_TITLE"

# Via REST API
curl -X POST "https://example.com/wp-json/wp/v2/media/$ATTACHMENT_ID" \
  -H "Authorization: Bearer $WP_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"alt_text\": \"$ALT_TEXT\", \"title\": {\"raw\": \"$SEO_TITLE\"}, \"caption\": {\"raw\": \"$CAPTION\"}}"
```

## Quality Checks

| Check | Criteria |
|-------|----------|
| Alt text length | 5-125 characters |
| Filename format | Lowercase, hyphens, no special chars |
| Tag count | 5-10 per image |
| Image dimensions | Min 1200px wide (social sharing) |
| File size | Under 200KB for web (see `seo/upscale.md`) |
| Format | WebP preferred, JPEG fallback, PNG for transparency |

## Schema.org ImageObject

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

## Integration Points

| Component | Purpose |
|-----------|---------|
| `seo/moondream.md` | Vision API for image analysis |
| `seo/upscale.md` | Quality enhancement before publishing |
| `seo/debug-opengraph.md` | Validate OG image after optimization |
| `seo/site-crawler.md` | Audit existing images for missing alt text |
| `seo/seo-audit-skill.md` | Image optimization checklist |
| `seo/schema-validator.md` | Validate ImageObject structured data |
| `tools/wordpress/wp-dev.md` | WordPress media management |
| `content.md` | Content creation with optimized images |

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

**Purpose**: Optimize images for search engines via AI vision analysis.
**Coordinates**: `seo/moondream.md` (vision) + `seo/upscale.md` (quality)
**Input**: Image URL, local path, or base64 | **Output**: filename, alt text, tags, optional upscale

<!-- AI-CONTEXT-END -->

## Workflow: Single Image

```bash
# Alt text
CAPTION=$(curl -s -X POST https://api.moondream.ai/v1/caption \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\", \"length\": \"normal\"}" \
  | jq -r '.caption')

# SEO filename
FILENAME=$(curl -s -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\",
    \"question\": \"Suggest a descriptive SEO-friendly filename using lowercase hyphenated words. No extension. Example: golden-retriever-wooden-deck\"
  }" | jq -r '.answer')

# Keyword tags
TAGS=$(curl -s -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\",
    \"question\": \"List 5-10 relevant SEO keywords for this image, comma-separated. Include subject, setting, colors, mood.\"
  }" | jq -r '.answer')
```

## Workflow: Batch

```bash
for img in /path/to/images/*.{jpg,png,webp}; do
  B64=$(base64 -i "$img" | tr -d '\n')
  IMAGE_DATA="data:image/jpeg;base64,$B64"
  ALT=$(curl -s -X POST https://api.moondream.ai/v1/caption \
    -H 'Content-Type: application/json' \
    -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
    -d "{\"image_url\": \"$IMAGE_DATA\", \"length\": \"normal\"}" | jq -r '.caption')
  NAME=$(curl -s -X POST https://api.moondream.ai/v1/query \
    -H 'Content-Type: application/json' \
    -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
    -d "{\"image_url\": \"$IMAGE_DATA\",
      \"question\": \"Suggest a descriptive SEO-friendly filename using lowercase hyphenated words. No extension.\"
    }" | jq -r '.answer')
  echo "$img -> $NAME.${img##*.} | Alt: $ALT"
done
```

## WordPress Integration

```bash
# WP-CLI
wp media update $ATTACHMENT_ID --alt="$ALT_TEXT" --title="$SEO_TITLE"

# REST API
curl -X POST "https://example.com/wp-json/wp/v2/media/$ATTACHMENT_ID" \
  -H "Authorization: Bearer $WP_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"alt_text\": \"$ALT_TEXT\", \"title\": {\"raw\": \"$SEO_TITLE\"}, \"caption\": {\"raw\": \"$CAPTION\"}}"
```

## Alt Text Rules (WCAG 2.1)

| Rule | Example |
|------|---------|
| Specific and concise | "Golden retriever on wooden deck" not "A dog" |
| Content, not format | Omit "Photo of…" / "Image showing…" |
| Include context | "CEO Jane Smith at annual conference" |
| Decorative images | `alt=""` |
| Max ~125 characters | Screen readers truncate longer text |
| Keywords naturally | Relevant terms, no stuffing |

**Prompt**: *Describe this image in one sentence for alt text. Specific subject, action, setting. No "A photo/image/picture of". Under 125 chars. Include key text if present.*

## Filename Conventions

| Rule | Example |
|------|---------|
| Lowercase | `golden-retriever.jpg` |
| Hyphens not underscores | `red-running-shoes.jpg` |
| Descriptive | `nike-air-max-90-white.jpg` not `IMG_4521.jpg` |
| Primary keyword included | `organic-coffee-beans-bag.jpg` |
| No special characters | No spaces, accents, symbols |
| 3–6 words, under 60 chars | `golden-retriever-wooden-deck` |

**Prompt**: *SEO-friendly filename, lowercase hyphenated, no extension. Main subject + one detail. 3–6 words. Example: golden-retriever-wooden-deck*

## Tag Extraction

Tags feed: WordPress tags/categories, `schema.org ImageObject keywords`, Open Graph, internal CMS search, IPTC/XMP fields.

**Prompt**: *List 5–10 keywords, comma-separated. Include: subject, setting, dominant colors, mood, notable objects. Most to least relevant.*

## Quality Checks

| Check | Threshold |
|-------|-----------|
| Alt text length | 5–125 characters |
| Filename format | Lowercase, hyphens, no special chars |
| Tag count | 5–10 per image |
| Dimensions | Min 1200px wide for social sharing |
| File size | Under 200KB for web |
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

| Component | Role |
|-----------|------|
| `seo/moondream.md` | Vision API — analysis engine |
| `seo/upscale.md` | Quality enhancement before publishing |
| `seo/debug-opengraph.md` | Validate OG image after optimization |
| `seo/site-crawler.md` | Audit existing images for missing alt text |
| `seo/seo-audit-skill.md` | Image optimization checklist |
| `seo/schema-validator.md` | Validate ImageObject structured data |
| `tools/wordpress/wp-dev.md` | WordPress media management |
| `content.md` | Content creation with optimized images |

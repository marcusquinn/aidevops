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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Image SEO Enhancement

Coordinates `seo/moondream.md` (vision) + `seo/upscale.md` (quality). Input: image URL, local path, or base64. Output: filename, alt text, tags, optional upscale.

## Workflow

```bash
# Single image — set IMAGE_URL or IMAGE_DATA (base64: "data:image/jpeg;base64,$B64")
CAPTION=$(curl -s -X POST https://api.moondream.ai/v1/caption \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\", \"length\": \"normal\"}" | jq -r '.caption')

FILENAME=$(curl -s -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\", \"question\": \"Suggest a descriptive SEO-friendly filename using lowercase hyphenated words. No extension. Example: golden-retriever-wooden-deck\"}" \
  | jq -r '.answer')

TAGS=$(curl -s -X POST https://api.moondream.ai/v1/query \
  -H 'Content-Type: application/json' \
  -H "X-Moondream-Auth: $MOONDREAM_API_KEY" \
  -d "{\"image_url\": \"$IMAGE_URL\", \"question\": \"List 5-10 relevant SEO keywords for this image, comma-separated. Include subject, setting, colors, mood.\"}" \
  | jq -r '.answer')

# Batch — wrap the above in a loop, substituting IMAGE_URL with base64 IMAGE_DATA per file
for img in /path/to/images/*.{jpg,png,webp}; do
  B64=$(base64 -i "$img" | tr -d '\n')
  IMAGE_URL="data:image/jpeg;base64,$B64"
  # ... run CAPTION / FILENAME / TAGS calls above ...
  echo "$img -> $FILENAME.${img##*.} | Alt: $CAPTION"
done
```

## WordPress Integration

```bash
# WP-CLI
wp media update $ATTACHMENT_ID --alt="$CAPTION" --title="$FILENAME"

# REST API
curl -X POST "https://example.com/wp-json/wp/v2/media/$ATTACHMENT_ID" \
  -H "Authorization: Bearer $WP_TOKEN" -H 'Content-Type: application/json' \
  -d "{\"alt_text\": \"$CAPTION\", \"title\": {\"raw\": \"$FILENAME\"}, \"caption\": {\"raw\": \"$CAPTION\"}}"
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
| Lowercase, hyphens | `red-running-shoes.jpg` (not underscores) |
| Descriptive | `nike-air-max-90-white.jpg` not `IMG_4521.jpg` |
| Primary keyword first | `organic-coffee-beans-bag.jpg` |
| 3–6 words, under 60 chars | `golden-retriever-wooden-deck` |
| No special characters | No spaces, accents, symbols |

**Prompt**: *SEO-friendly filename, lowercase hyphenated, no extension. Main subject + one detail. 3–6 words. Example: golden-retriever-wooden-deck*

## Tag Extraction

Feeds: WordPress tags/categories, `schema.org ImageObject keywords`, Open Graph, CMS search, IPTC/XMP.

**Prompt**: *List 5–10 keywords, comma-separated. Subject, setting, dominant colors, mood, notable objects. Most to least relevant.*

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

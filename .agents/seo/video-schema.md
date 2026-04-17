---
description: Video schema markup reference — VideoObject, Clip, Speakable, FAQPage/HowTo with video for rich results and LLM retrieval
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Video Schema Markup

Structured data for video content. Powers Google Key Moments, video carousels, rich snippets, and LLM citation. Reusable across: video pages, blog posts with embedded video, podcast episodes, programmatic content templates.

## VideoObject (Required for All Video Pages)

```json
{
  "@context": "https://schema.org",
  "@type": "VideoObject",
  "name": "How to Make Cold Brew Coffee",
  "description": "Step-by-step cold brew guide with ratio science and steeping times.",
  "thumbnailUrl": "https://example.com/cold-brew-thumb.jpg",
  "uploadDate": "2026-01-15T08:00:00+00:00",
  "duration": "PT8M30S",
  "contentUrl": "https://example.com/videos/cold-brew.mp4",
  "embedUrl": "https://www.youtube.com/embed/VIDEO_ID",
  "interactionStatistic": {
    "@type": "InteractionCounter",
    "interactionType": "https://schema.org/WatchAction",
    "userInteractionCount": 12400
  }
}
```

**Required fields**: `name`, `description`, `thumbnailUrl`, `uploadDate`.
**For Key Moments eligibility**: add `hasPart` with `Clip` segments.

## Clip (Google Key Moments)

Add `hasPart` array to `VideoObject`. Each `Clip` maps to one chapter.

```json
"hasPart": [
  {
    "@type": "Clip",
    "name": "Cold Brew Ratio",
    "startOffset": 90,
    "endOffset": 240,
    "url": "https://youtu.be/VIDEO_ID?t=90"
  },
  {
    "@type": "Clip",
    "name": "Steeping Time",
    "startOffset": 240,
    "endOffset": 390,
    "url": "https://youtu.be/VIDEO_ID?t=240"
  }
]
```

`startOffset` and `endOffset` are in seconds. `name` must match a search query for Key Moments eligibility — use the same phrasing as YouTube chapter titles.

## Speakable

Marks page sections for TTS extraction and LLM retrieval prioritisation. Apply to the 1–3 paragraphs that directly answer the primary query.

```json
{
  "@context": "https://schema.org",
  "@type": "WebPage",
  "speakable": {
    "@type": "SpeakableSpecification",
    "cssSelector": ["#transcript p:first-of-type", "h2 + p"]
  },
  "url": "https://example.com/cold-brew-guide"
}
```

## FAQPage with VideoObject

Combine FAQ structured data with video for pages that answer multiple questions.

```json
[
  {
    "@context": "https://schema.org",
    "@type": "VideoObject",
    "name": "Cold Brew FAQ",
    "description": "Answers to the 5 most common cold brew questions.",
    "thumbnailUrl": "https://example.com/thumb.jpg",
    "uploadDate": "2026-01-15"
  },
  {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    "mainEntity": [
      {
        "@type": "Question",
        "name": "What is the cold brew coffee ratio?",
        "acceptedAnswer": {
          "@type": "Answer",
          "text": "The standard ratio is 1:8 coffee to water by weight for a concentrate."
        }
      }
    ]
  }
]
```

## HowTo with Video Steps

```json
{
  "@context": "https://schema.org",
  "@type": "HowTo",
  "name": "How to Make Cold Brew Coffee",
  "video": {
    "@type": "VideoObject",
    "name": "Cold Brew Tutorial",
    "thumbnailUrl": "https://example.com/thumb.jpg",
    "uploadDate": "2026-01-15",
    "embedUrl": "https://www.youtube.com/embed/VIDEO_ID"
  },
  "step": [
    {
      "@type": "HowToStep",
      "name": "Measure coffee",
      "text": "Weigh 100g of coarsely ground coffee.",
      "url": "https://youtu.be/VIDEO_ID?t=90"
    }
  ]
}
```

## Property Reference

| Property | Type | Notes |
|----------|------|-------|
| `name` | Text | Required; match page H1 |
| `description` | Text | Required; 150–300 chars |
| `thumbnailUrl` | URL | Required; min 1280×720 |
| `uploadDate` | ISO 8601 | Required |
| `duration` | ISO 8601 duration | `PT8M30S` = 8 min 30 sec |
| `contentUrl` | URL | Direct video file URL |
| `embedUrl` | URL | YouTube/Vimeo embed URL |
| `hasPart` | Clip[] | Key Moments segments |

## Validation

```bash
# Google Rich Results Test (CLI)
curl -s "https://searchconsole.googleapis.com/v1/urlInspection/index:inspect" \
  -H "Authorization: Bearer $GSC_TOKEN" \
  -d '{"inspectionUrl":"https://example.com/cold-brew-guide","siteUrl":"https://example.com/"}'

# Schema.org local validator
npx schema-dts-gen --validate schema.json
```

Or use `seo/schema-validator.md` for local and bulk validation.

## Integration Points

| Component | Role |
|-----------|------|
| `seo/video-seo.md` | Three-surface strategy; schema is the Key Moments enabler |
| `seo/transcript-seo.md` | Speakable markup targets transcript paragraphs |
| `seo/rich-results.md` | VideoObject and Clip are rich result types |
| `seo/schema-validator.md` | Validate VideoObject, Clip, Speakable locally |
| `seo/programmatic-seo.md` | Template VideoObject at scale for video content hubs |
| `seo/seo-audit-skill.md` | Video schema as part of technical SEO audit |

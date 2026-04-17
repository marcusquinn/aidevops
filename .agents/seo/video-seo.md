---
description: Video SEO orchestrator — three-surface ranking (YouTube native / Google Key Moments / LLM answer engines)
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

# Video SEO

Video is a content atom that must rank across three surfaces simultaneously. Each surface has distinct ranking signals; a video optimised for only one surface leaves 66% of potential reach untapped.

## Three-Surface Model

| Surface | Primary Signal | Ranking Factors |
|---------|---------------|-----------------|
| **YouTube native** | CTR × average view duration | Title, thumbnail, chapters, engagement, watch time |
| **Google Key Moments** | `Clip` schema + chapter timestamps | `startOffset`/`endOffset`, title match to query |
| **LLM answer engines** | Transcript text retrieval | Verbatim query match in transcript, `Speakable` markup |

## YouTube Optimisation

**Title**: Primary keyword in first 60 chars. "How to [do X] in [year]" outperforms generic labels.

**Description** (first 150 chars shown in SERP):

```text
[Primary keyword] — [value proposition in one sentence].
Chapters: 0:00 Intro | 1:30 [Topic 1] | 4:00 [Topic 2]
```

**Chapters**: Add timestamps aligned to sub-queries (one chapter per audience question). Each chapter title is a standalone ranking signal for Key Moments.

**Tags**: 5–10 only. Primary keyword first, then variants, then broad category. Stuffing reduces relevance weighting.

**Thumbnail**: Face + contrast + 3-word text overlay. Target >4% CTR; below 3% triggers algorithmic suppression.

## Google Key Moments

Eligible when: video hosted on YouTube or with `VideoObject` + `Clip` schema. Google extracts chapters from description timestamps automatically; explicit `Clip` schema takes precedence.

```json
{
  "@context": "https://schema.org",
  "@type": "VideoObject",
  "name": "How to Make Cold Brew Coffee",
  "description": "Step-by-step guide with ratio science",
  "thumbnailUrl": "https://example.com/cold-brew-thumb.jpg",
  "uploadDate": "2026-01-15",
  "duration": "PT8M30S",
  "hasPart": [
    {
      "@type": "Clip",
      "name": "Cold Brew Ratio",
      "startOffset": 90,
      "endOffset": 240,
      "url": "https://youtu.be/VIDEO_ID?t=90"
    }
  ]
}
```

See `seo/video-schema.md` for complete schema reference.

## LLM Answer Engine Optimisation

LLMs cite video via transcript retrieval — not metadata. Transcript quality is the primary signal.

**Checklist**:

- [ ] Auto-generated captions corrected (names, technical terms, numbers)
- [ ] Transcript published as crawlable HTML on the same URL as the video embed
- [ ] Key claims phrased as full sentences (not fragment headers)
- [ ] `Speakable` schema marks the 1–3 paragraphs most likely to answer target queries
- [ ] FAQ/HowTo schema added when content structure supports it

See `seo/transcript-seo.md` for transcript production and optimisation workflow.

## Keyword Research for Video

YouTube Autocomplete → "how to X", "X tutorial", "X explained". Video SERP features appear for: tutorials, reviews, recipes, "how to" queries, news. Use `seo/keyword-research.md` to validate search volume before production.

## Performance Metrics

| Metric | Healthy | Action |
|--------|---------|--------|
| CTR | >4% | Retest thumbnail/title variants |
| Avg. view duration | >40% | Improve hook (first 30s) |
| Key Moments impressions | Rising | Tune chapter timestamps |
| AI citation rate | Tracked | Improve transcript + Speakable |

## Integration Points

| Component | Role |
|-----------|------|
| `seo/transcript-seo.md` | Transcript production, optimisation, and LLM retrieval |
| `seo/video-schema.md` | Full schema reference: VideoObject, Clip, Speakable, FAQPage |
| `seo/rich-results.md` | Validate Key Moments eligibility in Search Console |
| `seo/schema-validator.md` | Validate VideoObject + Clip structured data |
| `seo/seo-write.md` | Transcript-to-article content repurposing |
| `seo/keyword-research.md` | Video keyword demand and intent validation |
| `seo/seo-audit.md` | Video optimisation checklist within full-site audit |

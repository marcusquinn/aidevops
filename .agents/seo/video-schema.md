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

## Chapters

| Chapter | Description |
|---------|-------------|
| [VideoObject](video-schema/videoobject.md) | Required schema for all video pages; required fields and Key Moments eligibility |
| [Clip / Key Moments](video-schema/clip-key-moments.md) | `hasPart` Clip segments for Google Key Moments; chapter timestamps |
| [Speakable](video-schema/speakable.md) | CSS selector markup for TTS extraction and LLM retrieval prioritisation |
| [FAQPage + VideoObject](video-schema/faqpage-video.md) | Combined FAQ and video structured data for multi-question pages |
| [HowTo + VideoObject](video-schema/howto-video.md) | HowTo schema with embedded video steps |
| [Property Reference](video-schema/property-reference.md) | All VideoObject properties — types, requirements, and notes |
| [Validation](video-schema/validation.md) | CLI commands and tools for validating video schema markup |

## Integration Points

| Component | Role |
|-----------|------|
| `seo/video-seo.md` | Three-surface strategy; schema is the Key Moments enabler |
| `seo/transcript-seo.md` | Speakable markup targets transcript paragraphs |
| `seo/rich-results.md` | VideoObject and Clip are rich result types |
| `seo/schema-validator.md` | Validate VideoObject, Clip, Speakable locally |
| `seo/programmatic-seo.md` | Template VideoObject at scale for video content hubs |
| `seo/seo-audit-skill.md` | Video schema as part of technical SEO audit |

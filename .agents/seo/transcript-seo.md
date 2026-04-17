---
description: Transcript SEO — transcript-as-retrieval-signal discipline for video, audio, podcast, and LLM/GEO workflows
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

# Transcript SEO

Transcripts are the primary LLM retrieval signal for spoken-word content. An LLM cannot watch a video or listen to audio — it reads the transcript. A poorly corrected auto-caption is the single highest-leverage fix in video/audio SEO.

## Why Transcripts Matter

| Consumer | What it reads |
|----------|--------------|
| Google index | Full transcript (crawlable HTML on page) |
| YouTube search | Auto-captions (uncorrected = noise) |
| LLM answer engines | Transcript retrieved from index; Speakable schema prioritised |
| Podcast aggregators | Show notes + episode description |
| Screen readers (WCAG) | Captions / transcript |

## Production Workflow

1. **Generate**: YouTube auto-captions, Whisper (`openai/whisper`), or Descript
2. **Correct**: Names, technical terms, numbers, acronyms — auto-captions average 80% accuracy; correction raises this to 98%+
3. **Segment**: Break into paragraphs at natural speech pauses (≤5 sentences per paragraph)
4. **Embed**: Publish as crawlable HTML on the video/podcast page (not PDF, not hidden `<div>`)
5. **Mark up**: Add `Speakable` schema to the 1–3 paragraphs that directly answer primary queries

## Transcript Quality Checklist

- [ ] All proper nouns, brand names, and product names corrected
- [ ] Numbers rendered as digits ("seven" → "7") when they carry meaning
- [ ] Speaker labels added for multi-person content (`[Host]:`, `[Guest]:`)
- [ ] Filler words removed (`um`, `uh`, `you know`) — reduces noise for LLM retrieval
- [ ] Paragraph breaks at topic shifts, not arbitrary line counts
- [ ] No `[inaudible]` placeholders — research or omit uncapturable sections

## Embedding on Page

```html
<!-- Transcript section — crawlable, not hidden -->
<section id="transcript" aria-label="Video transcript">
  <h2>Transcript</h2>
  <p>0:00 — In this video, we cover the three key ratios for cold brew coffee...</p>
  <p>1:30 — The standard immersion ratio is 1:8 coffee to water by weight...</p>
</section>
```

JavaScript-rendered transcripts (`display: none`, JS-gated) are not reliably crawled by Google. Use static HTML or server-side rendering.

## Speakable Schema

Marks transcript sections as high-priority for TTS and LLM extraction.

```json
{
  "@context": "https://schema.org",
  "@type": "WebPage",
  "speakable": {
    "@type": "SpeakableSpecification",
    "cssSelector": ["#transcript p:first-of-type", ".key-takeaway"]
  },
  "url": "https://example.com/cold-brew-guide"
}
```

Use `cssSelector` (not `xpath`) — Google's TTS pipeline primarily uses CSS selectors. Mark paragraphs that contain direct, full-sentence answers to the primary search query.

## LLM Retrieval Optimisation

LLMs retrieve by semantic similarity. Transcript paragraphs that match query intent in full sentences rank higher than bullet fragments.

| Anti-pattern | LLM retrieval impact | Fix |
|--------------|---------------------|-----|
| Fragment headers ("Coffee ratios") | Low signal density | Restate as a sentence: "The correct cold brew coffee-to-water ratio is 1:8 by weight." |
| Passive voice throughout | Reduced clarity score | Convert key claims to active voice |
| No crawlable HTML | Zero LLM retrieval | Publish transcript as static HTML |
| Duplicate auto-caption noise | Dilutes relevance | Correct captions before indexing |

## Cross-Format Reuse

Transcripts enable repurposing with no additional content production:

- **Blog post**: transcript → `seo/seo-write.md` article workflow
- **FAQ schema**: extract Q&A pairs from transcript → `seo/video-schema.md`
- **GEO snippets**: transcript paragraphs → `seo/geo-strategy.md` snippet optimisation
- **Hallucination defense**: transcript = canonical source for claim verification → `seo/ai-hallucination-defense.md`
- **Podcast show notes**: segment headings → SEO-optimised episode descriptions

## Integration Points

| Component | Role |
|-----------|------|
| `seo/video-seo.md` | Three-surface video ranking; transcript is one of three signals |
| `seo/video-schema.md` | Speakable, VideoObject, and Clip schema markup |
| `seo/geo-strategy.md` | GEO snippet selection from transcript |
| `seo/ai-hallucination-defense.md` | Transcript as canonical fact source for claim audits |
| `seo/seo-write.md` | Transcript-to-article repurposing workflow |
| `seo/seo-geo.md` | GEO optimisation commands using transcript content |

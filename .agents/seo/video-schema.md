---
description: Video structured data playbook - VideoObject, Clip, Speakable, FAQPage-video, HowTo-video JSON-LD for Google Key Moments and LLM retrieval
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Video Schema

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: make video content machine-readable for Google Search (Key Moments, video results, rich snippets) and LLM answer engines.
- **Surface**: host page that embeds the video — always the schema target, not YouTube's own page.
- **Core schemas**: `VideoObject` (every video), `Clip` (per chapter), `Speakable` (factual answer sentences), `FAQPage` or `HowTo` (when video structure matches).
- **Validate** with `seo/schema-validator.md` before publishing; preview rich result eligibility via `seo/rich-results.md`.

<!-- AI-CONTEXT-END -->

## Placement Rules

- **One `VideoObject` per video page**. Canonicalise the video to a single host URL; embeds on other pages carry no schema.
- Place JSON-LD inside `<script type="application/ld+json">` in `<head>` or immediately after `</header>`; do not inject via JavaScript (crawler parity varies).
- Every schema property must reflect what the user sees — inconsistency between schema and visible content is a policy violation.

## VideoObject — required on every video page

```json
{
  "@context": "https://schema.org",
  "@type": "VideoObject",
  "name": "How to Install the Example WordPress Plugin",
  "description": "Step-by-step tutorial showing installation of the Example plugin on WordPress 6.x, including license activation and first-run configuration.",
  "thumbnailUrl": [
    "https://example.com/thumbs/install-example-plugin-1x1.jpg",
    "https://example.com/thumbs/install-example-plugin-4x3.jpg",
    "https://example.com/thumbs/install-example-plugin-16x9.jpg"
  ],
  "uploadDate": "2026-04-01T09:00:00+00:00",
  "duration": "PT8M42S",
  "contentUrl": "https://example.com/videos/install-example-plugin.mp4",
  "embedUrl": "https://example.com/embed/install-example-plugin",
  "publisher": {
    "@type": "Organization",
    "name": "Example Co",
    "logo": {
      "@type": "ImageObject",
      "url": "https://example.com/logo.png"
    }
  },
  "transcript": "Full plain-text transcript goes here, 200-5000 words, matching spoken audio word for word.",
  "inLanguage": "en-GB"
}
```

### Field rules

| Field | Requirement |
|-------|-------------|
| `name` | 50-70 chars; contains primary keyword |
| `description` | 150-300 chars; primary keyword in first 150 chars |
| `thumbnailUrl` | Array; supply 1x1, 4x3, 16x9 at minimum 1200 px wide |
| `uploadDate` | ISO 8601 with timezone |
| `duration` | ISO 8601 duration (`PT8M42S` = 8 min 42 s) |
| `contentUrl` | Direct media URL (mp4 / hls) when possible |
| `embedUrl` | Player iframe URL; alternative when `contentUrl` is DRM / private |
| `transcript` | Plain-text transcript; essential for LLM extraction |
| `inLanguage` | BCP-47 locale code |

Optional but high-value: `thumbnailUrl` with `width`/`height`, `interactionStatistic` (view count), `hasPart` (Clip array), `potentialAction` (SeekToAction for Key Moments).

## Clip — chapter-level retrieval targets

One `Clip` per chapter. Google Key Moments pulls titles + offsets from here. Nest under `VideoObject.hasPart` OR publish as separate `Clip` objects linked by `isPartOf`.

```json
{
  "@type": "Clip",
  "name": "How do you activate the license key?",
  "startOffset": 125,
  "endOffset": 214,
  "url": "https://example.com/install-example-plugin#t=125"
}
```

### Clip rules

- `name` should be **question-framed** where the search intent is a question. LLMs match user queries to clip names.
- `startOffset` / `endOffset` in **seconds from video start** (integer).
- `url` uses `#t=SS` fragment so the link jumps to the chapter.
- Duration (`endOffset - startOffset`) >= 10 s; shorter clips are ignored.
- Match the visible chapter markers in the player — inconsistency triggers policy warnings.

### SeekToAction (Key Moments enablement)

Add to parent `VideoObject` so Google knows the player supports deep-linking:

```json
{
  "@type": "VideoObject",
  "...": "...",
  "potentialAction": {
    "@type": "SeekToAction",
    "target": "https://example.com/install-example-plugin?t={seek_to_second_number}",
    "startOffset-input": "required name=seek_to_second_number"
  }
}
```

## Speakable — LLM factual-answer hinting

Tells voice assistants and some LLM surfaces which sentences are safe to quote verbatim. Apply to 2-3 highest-value sentences per page.

```json
{
  "@context": "https://schema.org",
  "@type": "WebPage",
  "speakable": {
    "@type": "SpeakableSpecification",
    "cssSelector": [".answer-lead", ".key-takeaway"]
  }
}
```

Use `cssSelector` (preferred) or `xpath`. Mark only sentences that are accurate, self-contained, and would read well aloud.

## FAQPage — video Q&A structure

When video content is Q&A (interviews, FAQ videos, AMA), mirror the structure in `FAQPage` on the host page. Each `Question` + `acceptedAnswer` maps to one chapter.

```json
{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [
    {
      "@type": "Question",
      "name": "How do you activate the license key?",
      "acceptedAnswer": {
        "@type": "Answer",
        "text": "Open the plugin settings page, paste the key into the License field, click Activate. The key is validated against the licensing server and the activation tier is displayed."
      }
    }
  ]
}
```

Answer text should match the transcript's factual claim, not paraphrase it — LLM cross-checks the schema against the transcript.

## HowTo — tutorial videos

For step-by-step tutorials where video chapters == steps.

```json
{
  "@context": "https://schema.org",
  "@type": "HowTo",
  "name": "How to Install the Example WordPress Plugin",
  "totalTime": "PT8M42S",
  "supply": [{"@type": "HowToSupply", "name": "Example plugin ZIP"}],
  "tool": [{"@type": "HowToTool", "name": "WordPress admin access"}],
  "step": [
    {
      "@type": "HowToStep",
      "name": "Upload the plugin ZIP",
      "text": "In WordPress admin, go to Plugins > Add New > Upload Plugin. Choose the Example plugin ZIP.",
      "url": "https://example.com/install-example-plugin#t=0",
      "image": "https://example.com/thumbs/step-1-upload.jpg"
    }
  ]
}
```

### HowTo rules

- Each step's `url` points to the relevant chapter (`#t=SS`).
- Each step's `image` should be a screenshot at the relevant chapter — not the full thumbnail.
- `totalTime` matches video duration.
- Do not use `HowTo` for videos that are not actually step-by-step (risk of manual policy action).

## Composition — per page type

| Page content | Required | Recommended |
|--------------|----------|-------------|
| Single tutorial video | `VideoObject` + `Clip[]` + `SeekToAction` | `HowTo`, `Speakable` |
| Q&A video | `VideoObject` + `Clip[]` | `FAQPage`, `Speakable` |
| Marketing / brand video | `VideoObject` | `Clip[]` if chapters present |
| Long-form podcast episode (audio + video) | `VideoObject` + `Clip[]` | `PodcastEpisode`, `Speakable` |
| Webinar recording | `VideoObject` + `Clip[]` | `Event` with `recordedIn` |
| News video | `VideoObject` | `NewsArticle` wrapping |
| Live-stream (past / upcoming) | `VideoObject` with `publication: BroadcastEvent` | — |

## Validation

```bash
# Validate locally via schema-validator helper
~/.aidevops/agents/scripts/schema-validator-helper.sh validate https://example.com/install-example-plugin

# Or paste the JSON-LD block into:
# - Schema.org validator: https://validator.schema.org/
# - Google Rich Results Test: https://search.google.com/test/rich-results
# - Google Search Console > Enhancements > Video after indexing

# Check on-page schema renders (not JS-injected after hydration)
curl -sL "https://example.com/install-example-plugin" | grep -c "application/ld+json"
# Must return >= 1
```

See `seo/schema-validator.md` for the validator tool and `seo/rich-results.md` for rich-results eligibility preview.

## Common Mistakes

| Mistake | Effect |
|---------|--------|
| `contentUrl` points to YouTube watch page (not media file or embed URL) | Google cannot index the media; falls back to YouTube's own schema |
| `duration` in seconds instead of ISO 8601 | Rejected by validator |
| `Clip` offsets that exceed video duration | Warnings; Key Moments may drop the clip |
| `Clip` name is a topic label ("Installation"), not a question ("How do I install?") | Lower LLM intent-match rate |
| Single thumbnail URL (string) instead of array of aspect ratios | Loses rich-result variety |
| Schema injected via JavaScript after page load | Some crawlers miss it; prefer server-rendered |
| `transcript` field omitted | Forfeits LLM transcript-extraction signal — the biggest single loss |
| Schema claims features the page does not visibly provide | Policy risk; manual action possible |
| Multiple `VideoObject` blocks for the same video (e.g., from plugins stacking) | De-duplicate; one authoritative block |

## Integration Points

| Component | Role |
|-----------|------|
| `seo/video-seo.md` | Parent agent — calls this for schema layer |
| `seo/transcript-seo.md` | Provides the transcript text that populates `VideoObject.transcript` |
| `seo/schema-validator.md` | Validate JSON-LD before publish |
| `seo/rich-results.md` | Preview rich-result eligibility |
| `seo/programmatic-seo.md` | Batch-generate `VideoObject` across a library of videos |
| `seo/ai-search-readiness.md` | Schema presence is a readiness metric |
| `content/distribution-blog.md` | Blog posts that embed video carry `VideoObject` on the host page |
| `content/distribution-youtube.md` | YouTube auto-generates basic schema on youtube.com; the host-page schema is separate and authoritative |
| `tools/wordpress/wp-dev.md` | WP plugins (Yoast, Rank Math, Schema Pro) emit `VideoObject` — audit output |

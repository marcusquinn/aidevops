---
description: Video SEO across YouTube native, Google Search (Key Moments), and LLM answer engines - transcript-first retrieval optimisation
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

# Video SEO

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Core shift (2026)**: video is one content atom ranking across **three surfaces simultaneously** — YouTube native, Google Search (Key Moments, universal results), LLM answer engines (ChatGPT, Perplexity, Gemini, Google AI Overviews).
- **LLMs don't watch — they read**: transcripts, metadata, schema, on-page HTML. Audio-only production is invisible to AI search.
- **Primary retrieval signal**: accurate transcript with spoken target keywords + named entities. Auto-captions alone forfeit citation eligibility.
- **Companion subagents**: `transcript-seo.md` (caption discipline), `video-schema.md` (VideoObject / Clip / Speakable / FAQ-HowTo-video).

<!-- AI-CONTEXT-END -->

## Three-Surface Model

| Surface | What it uses | Dominant signal | Cadence |
|---------|-------------|-----------------|---------|
| **YouTube native** | Title, description, tags, captions, thumbnail, retention, CTR | Session watch time | Ranks within hours |
| **Google Search** | Schema (`VideoObject`, `Clip`), thumbnails, transcript text, page context, sitemap | Structured data + page authority | Days to weeks |
| **LLM answer engines** | Transcript text, schema-extracted facts, host-page text, external citations | Retrievable factual density in text form | Varies; measured via citation-tracking tools |

One video, one keyword cluster, **three optimisation passes** — never optimise for one surface and hope the others follow. CTR signals (see `content/distribution-youtube-optimizer.md`) help YouTube; schema + transcript help the other two.

## Three-Surface Checklist (per video)

```text
YouTube native
  - Primary keyword in first 60 chars of title + first 150 chars of description
  - 5-8 chapter timestamps, question-framed where possible
  - Accurate captions uploaded (not auto-only) -> transcript-seo.md
  - Thumbnail passes mobile 120x90 test -> distribution-youtube-optimizer.md
  - End screen + pinned comment reinforcing CTA

Google Search (Key Moments + universal results)
  - VideoObject schema on host page -> video-schema.md
  - Clip schema for each chapter (title + startOffset + endOffset)
  - Video sitemap submitted; thumbnail_loc and description present
  - Transcript published as HTML on the host page, not image/PDF
  - Canonical embed tag pointing to the host page for syndication

LLM answer engines
  - Transcript contains spoken target keywords naturally (no stuffing)
  - Named entities spelled out first reference ("Google Search Console", not "GSC")
  - Speakable schema on 2-3 highest-value sentences per page
  - Host page first 200 words dense with the video's factual claims
  - FAQPage or HowTo schema mirroring the video's Q&A structure
```

## Transcript Discipline (summary)

Full rules: `seo/transcript-seo.md`. Core:

- **Accuracy >= 95%** human-reviewed; auto-captions alone disqualify from LLM citation (industry convergence signal).
- **Spoken keywords** — primary and 2-3 supporting keywords appear in the spoken audio, not only on-screen text, so transcript text carries them.
- **Named entities on first mention** — "WordPress plugin" before "the plugin"; proper nouns spelled out.
- **Publish transcript as HTML** on the host page with speaker labels and timestamps; not an embedded PDF or transcript-video-only platform.
- **Wistia LLM-Friendly Embed Codes** (or equivalent) — makes transcript HTML-visible in the embed, not iframe-hidden.

## Schema Playbook (summary)

Full playbook with JSON-LD: `seo/video-schema.md`. Minimum per video:

| Schema | When | Key properties |
|--------|------|---------------|
| `VideoObject` | Every video page | `name`, `description`, `thumbnailUrl`, `uploadDate`, `duration` (ISO 8601), `contentUrl`, `embedUrl`, `transcript` |
| `Clip` | Videos with chapters | `name` (question-framed), `startOffset`, `endOffset`, `url` with `#t=` fragment |
| `Speakable` | Factual answer pages | `cssSelector` or `xpath` on 2-3 highest-value sentences |
| `FAQPage` | Q&A videos | Mirror transcript Q&A in structured form |
| `HowTo` | Tutorial videos | `step` array each with `image`, `name`, `text`; match video chapters |

Validate via `seo/schema-validator.md` before publishing.

## Chapter Timestamps as AI-Citable Sections

Chapters are not just UX — they are the **retrieval units** Google Key Moments and LLMs quote from. Rules:

- **Question-framed titles** where the search intent is a question: "How do you install X?" not "Installation". LLMs match queries to chapter titles.
- **5-15 chapters**, minimum 10s each, minimum 3 for Key Moments eligibility.
- **First chapter at 00:00** (YouTube requirement).
- **Chapter title duplicated in transcript** near the timestamp so the extracted clip has context.
- Match chapter titles to keyword cluster's long-tail variations (`query-fanout-research.md`).

## Shorts vs Long-Form Keyword Strategy (MANDATORY separate)

Industry data (marketingagent.blog 2026): 67% of creators reuse the same keyword on Shorts and long-form, halving both. Rule:

- **Long-form** — primary keyword with informational/commercial intent; answers a durable question.
- **Shorts** — reactive/trending keyword, high-velocity search pattern, or emotional-hook keyword; separate cluster.
- Link from the Short's description to the long-form video; do not cross-compete.
- See `content/distribution-short-form.md` for Shorts production; see `seo/keyword-research.md` for cluster separation.

## Self-Hosted Video SEO (when not on YouTube)

Applies to Wistia, Vimeo Pro, VdoCipher, self-hosted HLS, etc.

| Rule | Why |
|------|-----|
| Submit a **video sitemap** (`<url><video:video>...`) with thumbnail, title, description, duration, content_loc | Google video indexing entry point |
| **One video per URL** canonical; embeds point back with `rel=canonical` | Avoids duplicate content across pages that embed the same video |
| Transcript is **HTML on the host page**, not inside the player iframe | Iframe text is invisible to most crawlers and LLMs |
| Poster image at the top of page, transcript + key-moments below the fold | CLS/LCP friendly; matches Google's "video" universal result layout |
| Fast first-frame render (< 2.5 s LCP); test via `pagespeed` | Page-speed is a ranking factor; video-heavy pages fail without tuning |
| Caption file (WebVTT) served uncompressed to search engines | Enables Google to extract Key Moments |

See `tools/browser/pagespeed.md` for measurement.

## Multimodal Content Stack

One keyword cluster produces **four mutually-reinforcing assets**:

1. **Long-form video** (8-20 min) on YouTube + canonical host page
2. **Blog post** on the host page with video embedded + transcript + expanded commentary
3. **Short** (15-60 s) targeting the reactive variant of the keyword
4. **Podcast episode** (audio-only extract or expansion) with its own transcript

All four link inward to the host page; host page carries the canonical schema and is the LLM citation target. This pattern drives topical-authority signals and gives each surface an asset optimised for it. See `content.md` diamond pipeline.

## LLM Visibility Measurement

| Tool | Measures | Caveat |
|------|----------|--------|
| **HubSpot AI Search Grader** | Free baseline — whether your brand/video is citable on ChatGPT/Perplexity/Gemini for target queries | Prompts drift; re-baseline monthly |
| **Otterly.AI** | Tracks brand citations across LLMs and AI overviews over time | Subscription; best for multi-query tracking |
| **Goodie AI** | Competitor citation share analysis | Useful for gap-finding, not absolute benchmarks |
| **Glasp** | Transcript highlight-extraction patterns (what humans clip = likely LLM extract) | Proxy signal only |
| **UTM-tagged transcript links** | Direct attribution when LLMs cite with clickable link | Not all LLM surfaces link; coverage incomplete |

Cite `seo/ai-search-readiness.md` for the broader measurement scorecard.

## Pre-Publish Checklist (three-surface)

| Element | Check | Surface |
|---------|-------|---------|
| Title | 50-70 chars, primary KW, 2+ CTR signals | YouTube |
| Description first 150 chars | Contains primary KW naturally | YouTube + Google |
| Chapters | 5-15, question-framed, first at 00:00 | All three |
| Captions | Human-reviewed >= 95% accuracy | All three (LLM primary) |
| Transcript | Published as HTML on host page | Google + LLM |
| Named entities | Spelled out on first mention in transcript | LLM |
| Speaking cadence | Primary + 2-3 supporting KWs spoken naturally | LLM |
| `VideoObject` schema | Valid via schema-validator | Google + LLM |
| `Clip` schema | One per chapter with offsets | Google Key Moments |
| `Speakable` schema | 2-3 highest-value sentences | LLM |
| Thumbnail | 1280x720, passes mobile 120x90 test | YouTube + Google |
| Canonical URL | Host page, not YouTube (if self-hosted) | Google + LLM |
| Short variant | Separate KW from long-form | YouTube |
| Blog post | Embedded video + expanded transcript | Google + LLM |

## Anti-Patterns

- **Auto-caption reliance** — sub-95% accuracy forfeits LLM citation eligibility; fix before publishing.
- **Misleading titles** — LLMs score transcript-to-title consistency; clickbait degrades future citations.
- **Keyword stuffing in description** — Google devalues; transcript discipline is the real surface.
- **Same keyword on long-form + Short** — halves both; separate clusters.
- **Transcript locked inside iframe** — invisible to LLM crawlers; publish as page HTML.
- **Video with zero schema** — Google treats as generic page, no Key Moments eligibility.
- **Chapter titles as topic labels, not questions** — loses LLM intent-match opportunity.

## Integration Points

| Component | Role |
|-----------|------|
| `seo/transcript-seo.md` | Transcript accuracy, cadence, entity discipline (called by this agent) |
| `seo/video-schema.md` | `VideoObject` / `Clip` / `Speakable` / FAQ-HowTo-video JSON-LD playbook |
| `seo/schema-validator.md` | Validate structured data before publish |
| `seo/rich-results.md` | Rich results preview and eligibility |
| `seo/geo-strategy.md` | Page-level GEO criteria (video is one asset class) |
| `seo/ai-search-readiness.md` | End-to-end readiness scorecard |
| `seo/keyword-research.md` | KW cluster, volume, competition (incl. Shorts vs long-form) |
| `seo/query-fanout-research.md` | Sub-query map feeds chapter titles |
| `content/distribution-youtube-optimizer.md` | CTR signals for YouTube-native layer (complementary) |
| `content/distribution-youtube-script-writer.md` | Hook / retention / pattern interrupts (script-level) |
| `content/distribution-youtube-topic-research.md` | Topic and angle validation |
| `content/distribution-short-form.md` | Shorts production (separate KW) |
| `content/production-video.md` | Plan speaking lines to carry keywords |
| `tools/browser/pagespeed.md` | LCP / CLS for video pages |

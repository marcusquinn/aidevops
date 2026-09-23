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

Video must rank across three surfaces simultaneously; optimising for only one leaves the other two untapped.

## Three-Surface Model

| Surface | Primary Signal | Ranking Factors |
|---------|---------------|-----------------|
| **YouTube native** | CTR × average view duration | Title, thumbnail, chapters, engagement, watch time |
| **Google Key Moments** | `Clip` schema + chapter timestamps | `startOffset`/`endOffset`, title match to query |
| **LLM answer engines** | Transcript text retrieval | Verbatim query match in transcript, `Speakable` markup |

## YouTube Optimisation

**Title**: Primary keyword in first 60 chars. "How to [do X] in [year]" outperforms generic labels.

**Description** (first 150 chars shown in SERP): Primary keyword — value proposition. Include chapter timestamps inline: `0:00 Intro | 1:30 Topic 1 | 4:00 Topic 2`.

**Chapters**: Align timestamps to sub-queries (one chapter per audience question). Each chapter title is a standalone ranking signal for Key Moments.

**Tags**: 5–10 only. Primary keyword first, then variants, then broad category. Stuffing reduces relevance weighting.

**Thumbnail**: Face + contrast + 3-word text overlay. Target >4% CTR; below 3% triggers algorithmic suppression.

## Google Key Moments

Eligible when: video hosted on YouTube or with `VideoObject` + `Clip` schema. Google extracts chapters from description timestamps automatically; explicit `Clip` schema takes precedence.

Key Moments schema — add `hasPart` to your `VideoObject`:

```json
"hasPart": [
  {
    "@type": "Clip",
    "name": "Cold Brew Ratio",
    "startOffset": 90,
    "endOffset": 240,
    "url": "https://youtu.be/VIDEO_ID?t=90"
  }
]
```

See `seo/video-schema.md` for complete VideoObject + Clip schema reference.

## Google AI Overview citations from YouTube

For how-to content supported by an owned YouTube video, treat the spoken answer as
part of the search asset, not just the title and description. In a one-day study
of 600 US how-to-oriented questions (1,777 AI Overviews, desktop, September 2026),
83% of the AI Overviews cited at least one YouTube video; 36% of YouTube citations
linked to a specific second. In 80% of citations, the displayed video snippet
matched captions alone, versus 2% matching the description alone. These are
observations about **Google AI Overviews**, not all answer engines or a guarantee
of citation.

**Production bets to test**:

- Answer the exact audience question plainly near the start, ideally within the
  first 30 seconds, without withholding the useful step for a long intro. Among
  timestamped moments with captions, 58% fell in the first 30 seconds; this does
  not prove moving an answer earlier increases citations.
- Say the question's natural terms aloud at the answer, then name the step just
  before demonstrating it. Review the actual captions for errors; do not stuff
  scripted keywords. Google-linked moments often matched nearby speech, and the
  line at the linked second more often introduced the answer than adjacent lines.
- Make each supporting video answer a specific task completely; include accurate
  chapter markers around meaningful sections when useful to viewers. Chapters
  and channel size are not established ranking levers: cited videos often had
  fewer views than uncited YouTube top-ten videos for the same question, and the
  linked second was no more likely to land exactly on a chapter boundary.
- Consider a focused Short when the task can be answered briefly (22% of YouTube
  citations in the study went to Shorts); retain long-form when explanation needs
  it. Pair the video with the relevant owned page for user benefit, not on the
  assumption that a video citation transfers to the page.

**Measurement**: For a small, fixed panel of relevant questions, record the
locale/device/date, AI Overview presence, cited video and timestamp, snippet,
Google video-carousel position, owned-page citation, and referral/conversion
outcomes separately. Capture a baseline before changing a video's script or
chapters and rerun periodically with untreated comparison queries where practical.
Compare Google AI Overviews separately from AI Mode and other answer engines;
neither a citation nor a snippet proves the video supplied the answer text.

Source and limitations: [Ivan Builds, 23 September 2026](https://ivanbuilds.com/youtube-ai-overview-citations.html).
The sample spans 12 chosen topics on one US desktop day; repeated searches of
the same questions are not independent experiments, and several transcript
classifications were checked by other AI models rather than humans. Findings
are correlational; validate on our topics before treating these bets as policy.

## LLM Answer Engine Optimisation

For answer-engine retrieval, make the spoken content and its captions accurate and
accessible alongside useful metadata. Do not infer other engines' citation
mechanisms from the Google AI Overview study above.

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
| AI citation rate | Tracked by engine/query | Inspect cited moments and captions; test changes against a baseline |

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

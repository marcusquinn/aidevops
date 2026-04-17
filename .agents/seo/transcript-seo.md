---
description: Transcript-as-retrieval-signal - accuracy, spoken-keyword cadence, named entities, publish-as-HTML discipline for LLM citation eligibility
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

# Transcript SEO

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Thesis**: LLMs do not watch video. They read transcripts, metadata, and on-page HTML. A video without an accurate, HTML-visible transcript is **invisible to AI search**.
- **Primary metric**: transcript accuracy (target >= 95%, minimum 90%). Auto-captions alone (YouTube, TikTok, Reels) are ~70-85% on non-studio audio and forfeit citation eligibility.
- **Applies to**: YouTube video, self-hosted video, podcasts, webinars, any audio or video asset with an AI-search audience.

<!-- AI-CONTEXT-END -->

## Accuracy Targets

| Tier | Accuracy | Use case | Method |
|------|----------|----------|--------|
| Minimum | 90% | Internal, low-stakes | Auto-caption + quick manual pass |
| Standard | 95%+ | Public-facing content | Auto-caption + full human review |
| Premium | 98%+ | Cited research, documentation | Professional transcription service |

Auto-caption accuracy drops sharply on accents, technical terms, brand names, overlapping speech, and noisy audio. Never publish without at least one human review pass on these categories.

## Spoken-Keyword Cadence

Transcripts are the surface LLMs extract claims from. Keywords must be **spoken**, not only in on-screen text.

| Keyword tier | Spoken frequency | Placement |
|-------------|------------------|-----------|
| Primary (1 per video) | 3-7 times in 10 minutes | First 60 s, mid-video, recap |
| Supporting (2-3) | 1-3 times each | Distributed; each section at least once |
| Long-tail variations | Natural; do not force | Answer explicit questions |

Rule: if a viewer muted the video, the transcript should still carry the full topical argument with target keywords intact. Keyword stuffing is detectable — cadence must sound natural on read-back.

## Named Entity Discipline

LLMs build knowledge-graph associations from entity co-occurrence. Rules:

- **Spell out on first mention.** "Google Search Console" before "GSC"; "WordPress plugin" before "the plugin"; "Dr. Jane Smith, cardiologist" before "Jane".
- **Use canonical names** that match the entity's Wikipedia or knowledge-graph entry.
- **One canonical form per asset.** Do not mix "YouTube SEO" and "Youtube SEO" and "YT SEO" — pick one.
- **Brand disambiguation** — "Sora 2 Pro by OpenAI" not just "Sora" when homonyms exist.

## Caption File Format

| Format | Use | Notes |
|--------|-----|-------|
| **WebVTT (.vtt)** | Web players, HTML5 video, Google indexing | Preferred — supports cues, styling, positioning |
| SRT | Legacy, broad compatibility | Acceptable fallback |
| ASS / SSA | Karaoke / styled | Not for SEO |
| Embedded (YouTube) | YouTube only | Must upload SRT/VTT — not rely on auto-generated |

Always upload a manual caption file to YouTube even if you also allow auto-captions — manual file takes priority and controls what enters the transcript.

## Publish-as-HTML Requirement

**Transcript text must be visible to crawlers as HTML on the host page.** Common failure modes:

| Failure | Fix |
|--------|-----|
| Transcript only inside video iframe | Render to page HTML below the player |
| Transcript as downloadable PDF | Inline as HTML; link PDF as secondary |
| Transcript inside JavaScript-rendered tab | Server-render or static-render the tab's content |
| Transcript hidden in collapsed accordion (JS-only) | Allow open-by-default or server-render; `<details>` works |
| Transcript on a third-party site only (e.g. Otter share link) | Mirror onto host page |

**Wistia LLM-Friendly Embed Codes** and equivalents render the transcript as sibling HTML to the player iframe — use them if available on your video host.

## Transcript Page Layout (host page)

```text
1. H1 — video title (primary keyword)
2. Video player (< 2.5 s LCP)
3. 100-200 word summary paragraph (dense with entities + primary keyword)
4. Chapters list — question-framed, each linking to #t=SS anchor
5. Full transcript as HTML with:
   - Speaker labels ("Host:", "Guest:") if multi-speaker
   - Timestamps every 30-60 s as links
   - Paragraph breaks at topic shifts (not every line)
6. FAQ or HowTo section mirroring transcript Q&A (FAQPage / HowTo schema)
7. Related links (internal, same keyword cluster)
```

## Workflow

```bash
# Pull a YouTube video's existing captions (yt-dlp, 0 API units)
~/.aidevops/agents/scripts/yt-dlp-helper.sh transcript VIDEO_ID > transcript.vtt

# For a local video file or podcast, use the transcription helper
~/.aidevops/agents/scripts/transcription-helper.sh transcribe /path/to/video.mp4 \
  --model large-v3 --output /path/to/transcript.vtt

# Quality review checklist on the output
# 1. Accurate spellings of named entities?
# 2. Technical terms correct?
# 3. Punctuation and paragraph breaks sensible?
# 4. Speaker labels present (if multi-speaker)?
# 5. Timestamps aligned with speech (drift < 500 ms)?
```

See `tools/voice/transcription.md` for transcription engines (Whisper, AssemblyAI, Deepgram) and `scripts/transcription-helper.sh` for the shared helper.

## Pre-Production Rule (feeds script writing)

Scripts written with the transcript in mind save hours of post-production cleanup. Rule:

- **Plan the primary keyword into spoken lines** before recording. Draft a ~200-word summary of the factual claims the transcript will carry — if the keyword doesn't appear naturally, the topic is wrong or the framing is wrong.
- **First 60 seconds must carry the primary keyword spoken** (not only on-screen).
- Apply in `content/distribution-youtube-script-writer.md` pre-flight questions and in `content/production-video.md` shot planning.

## Measurement

| Metric | How to measure | Target |
|-------|---------------|--------|
| Transcript accuracy | Sample 100 words, count errors | >= 95% |
| Keyword cadence | Grep primary KW in transcript, count per 10 min | 3-7 |
| Entity coverage | List spoken entities vs page schema `mentions` field | 100% match |
| HTML visibility | `curl -L <page> \| grep "<key sentence>"` finds the text | Must return a hit |
| LLM citation eligibility | HubSpot AI Search Grader baseline for target query | Citable or gap identified |

See `seo/ai-search-readiness.md` for the broader readiness scorecard.

## Anti-Patterns

- **Relying on auto-captions** for public content — accuracy sub-90% on anything non-trivial.
- **Keyword stuffing the spoken audio** — sounds unnatural to listeners, detectable by LLMs.
- **Transcript hidden behind JS tab or PDF download** — invisible to crawlers.
- **One transcript, many pages** — duplicate content. Canonicalise to the host page.
- **Paraphrased transcript** — must match spoken audio word-for-word (otherwise a search for a quoted phrase won't match the page).
- **No speaker labels on multi-speaker content** — degrades readability and LLM extraction accuracy.

## Integration Points

| Component | Role |
|-----------|------|
| `seo/video-seo.md` | Parent agent — calls this for transcript layer |
| `seo/video-schema.md` | Transcript feeds `VideoObject.transcript` and `Speakable` selectors |
| `seo/ai-hallucination-defense.md` | Claim-evidence audits use transcript as source of truth |
| `seo/sro-grounding.md` | Snippet selection uses transcript text |
| `content/distribution-youtube-script-writer.md` | Pre-production planning carries keywords into spoken lines |
| `content/production-audio.md` | Audio quality affects transcription accuracy |
| `content/distribution-podcast.md` | Podcast transcripts follow the same discipline |
| `tools/voice/transcription.md` | Transcription engine selection |
| `scripts/transcription-helper.sh` | CLI wrapper for Whisper / AssemblyAI / Deepgram |
| `scripts/yt-dlp-helper.sh` | Pulls existing YouTube transcripts (0 API units) |

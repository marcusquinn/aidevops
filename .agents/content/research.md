---
name: research
description: Audience research, niche validation, and competitor analysis for content strategy
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Content Research

Pre-writing research to validate niches, understand audiences, and analyse competitors before committing to content production.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Audience research, niche validation, competitor content analysis
- **Input**: Topic, niche, or URL(s) to analyse
- **Output**: Research brief with audience profile, niche viability score, competitor gaps
- **Related**: `content/seo-writer.md` (uses research output), `content/context-templates.md` (stores findings), `tools/content/content-calendar.md` (prioritises topics)

<!-- AI-CONTEXT-END -->

## Pre-flight Questions

Before generating audience or market research, work through:

1. What are the first principles here — what is actually true vs commonly assumed?
2. What is the root cause, not the symptom?
3. What biases could be distorting this — confirmation, anchoring, availability, survivorship?
4. What is the evidence — and how reliable is the source?
5. Are there physics, psychology, or reliability constraints that limit what's possible?
6. What would disprove this conclusion?

## Workflow

### 1. Audience Research

**Data sources** (in priority order):

1. **Reddit Deep Research** — 11-Dimension Framework (see below)
2. **Google Search Console** (`seo/google-search-console.md`) — existing query data
3. **Competitor audiences** — analyse who engages with competitor content
4. **Creator Brain Clone** — bulk transcript ingestion (see below, references t201)
5. **Cross-platform signals** — TikTok/X/IG/Reddit for format migration patterns
6. **Web search** — industry reports, surveys, forum threads
7. **DataForSEO** (`seo/dataforseo.md`) — keyword volume and demographics

#### 11-Dimension Reddit Research Framework

Use Perplexity (or similar AI search) with this mega-prompt to extract deep insights from Reddit discussions.

```text
Analyze Reddit discussions about [TOPIC/PRODUCT/NICHE] across all relevant subreddits. Provide a comprehensive report covering these 11 dimensions:

1. SENTIMENT ANALYSIS — Overall sentiment, common praise/complaints, emotional tone
2. USER EXPERIENCE PATTERNS — Typical user journey, learning curve, common use cases, workflow integration
3. COMPETITOR COMPARISONS — Alternatives mentioned, head-to-head comparisons, migration patterns, feature gaps
4. PRICING & VALUE PERCEPTION — Price sensitivity, tier preferences, ROI discussions, deal-seeking behavior
5. USE CASES & APPLICATIONS — Primary use cases, creative/unexpected uses, industry-specific, beginner vs advanced
6. SUPPORT & COMMUNITY — Support quality, community helpfulness, documentation quality, onboarding
7. PERFORMANCE & RELIABILITY — Speed/performance, reliability issues, scalability, technical limitations
8. UPDATES & DEVELOPMENT — Feature request patterns, update frequency perception, breaking changes, roadmap transparency
9. POWER USER TIPS — Advanced techniques, workflow optimizations, hidden features, integration hacks
10. RED FLAGS & DEAL-BREAKERS — Reasons people quit, unresolved pain points, trust/security concerns, lock-in fears
11. DECISION SUMMARY — Who should use this, who should avoid it, key decision factors, alternatives

For each dimension, provide: direct quotes (exact user language), frequency indicators, subreddit sources, recency.
Focus on EXACT user language — their words, not marketing speak.
```

**Usage:** Replace `[TOPIC/PRODUCT/NICHE]`, run in Perplexity Pro, extract insights into audience profile template, store raw output in `context/reddit-research-[topic].md`.

#### 30-Minute Expert Method

1. **Reddit Scraping** (10 min) — Identify 3-5 relevant subreddits. Search "best [topic]", "vs", "alternative to", "frustrated with", "how to". Collect top 20-30 threads.
2. **NotebookLM Ingestion** (5 min) — Create project `[Niche] Research - [Date]`. Upload Reddit threads + competitor sites + existing research.
3. **AI-Powered Analysis** (15 min) — Ask: top 10 pain points, failed solutions, user language, common objections, ideal customer profile. Generate briefing doc.

**Output:** Pain points in exact user language, failed solutions, purchase triggers, objection patterns, ideal customer profile. Save to `context/expert-brief-[niche].md`.

#### Pain Point Extraction

Extract pain points in the EXACT language your audience uses (critical for hooks, copy, and resonance).

**Sources:** Reddit ("frustrated with", "problem with", "why does", "hate that") → Forum complaints (Quora, Facebook groups) → Product reviews (Amazon, G2, Capterra 1-3 star) → YouTube comments → Social media rants.

```markdown
## Pain Point: [Short Label]

**Exact Quote**: "[User's exact words]"
**Source**: [Platform + URL]
**Frequency**: [Common / Occasional / Rare]
**Severity**: [Deal-breaker / Major annoyance / Minor friction]
**Failed Solutions Tried**: [What they tried, why it failed]
**Desired Outcome**: [What they wish existed, how they'd know it's solved]
**Purchase Trigger**: [What would make them buy NOW]
```

After collecting 20-30 pain points: cluster by theme, rank by frequency + severity, identify language patterns, map to content opportunities. Store in `context/pain-points-[niche].md`.

#### Creator Brain Clone Pattern

Bulk ingest competitor channel transcripts to build a queryable competitive intelligence knowledge base (references t201).

```bash
# Download transcripts
yt-dlp-helper.sh transcripts @channelhandle --limit 50

# Store in memory with namespace
memory-helper.sh store --namespace youtube-[niche] --file transcripts/*.txt --auto

# Query for insights
memory-helper.sh recall --namespace youtube-[niche] "most common topics"
memory-helper.sh recall --namespace youtube-[niche] "video opening hooks"
memory-helper.sh recall --namespace youtube-[niche] "audience problems"
```

**What you learn:** Topic coverage, hook patterns, storytelling frameworks, pain points addressed, language patterns, content gaps. Store in memory namespace `youtube-[niche]` + `context/creator-intel-[niche].md`.

#### Gemini 3 Video Reverse-Engineering

Feed competitor videos to Gemini 3 to extract reproducible prompts for your own video generation.

1. Identify high-performing competitor videos (top by views, viral short-form, long-running ads)
2. Upload to Gemini 3 with this prompt:

```text
Analyze this video and provide:
1. VISUAL STYLE — Camera angles, lighting, color grading, composition
2. SCENE BREAKDOWN — Shot-by-shot with timestamps, B-roll, text overlays, transitions
3. AUDIO DESIGN — Voice style, background music, sound effects, audio mixing
4. PACING & EDITING — Average shot length, cut frequency, retention hooks
5. REPRODUCIBLE PROMPT — Generate a Sora 2 / Veo 3.1 prompt that would recreate this style
```

3. Save working prompts to `context/video-styles/[style-name].md` (tagged by niche, format, production value, emotion).

**Related:** `content/production/video.md`, `tools/video/video-prompt-design.md`.

#### Cross-Platform Research

| Platform | Research Focus |
|----------|---------------|
| Reddit | Pain points, product discussions, buying intent |
| TikTok | Trending formats, viral hooks, short-form patterns |
| X (Twitter) | Real-time trends, hot takes, thread structures |
| Instagram | Visual trends, carousel formats, Reels patterns |
| YouTube | Long-form depth, tutorial formats, retention patterns |
| LinkedIn | B2B angles, professional pain points, case studies |

Watch for content performing well on one platform that hasn't migrated to others. Track in a cross-platform matrix:

| Topic | Reddit | TikTok | X | IG | YouTube | LinkedIn | Blog |
|-------|--------|--------|---|----|---------|---------| ------|
| [topic] | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ |

`✓` = exists, `○` = opportunity, `✗` = poor fit. **Related:** `content/distribution/` for platform-specific adaptation guides.

**Audience profile template:**

```markdown
## Audience Profile: [Segment Name]

- **Who**: [Job title / role / demographic]
- **Pain points**: [Top 3 — use exact language from research]
- **Failed solutions**: [What they've tried that didn't work]
- **Goals**: [What success looks like]
- **Knowledge level**: [Beginner / Intermediate / Expert]
- **Where they hang out**: [Platforms, forums, communities]
- **Content preferences**: [Format: video, long-form, quick tips, tools]
- **Search behaviour**: [Question-style, comparison, how-to]
- **Buying triggers**: [What moves them from research to action]
- **Exact language**: [Key phrases they use repeatedly]
```

**Validation signals** (at least 2 required before proceeding):

| Signal | Source | Threshold |
|--------|--------|-----------|
| Search volume exists | DataForSEO / GSC | >100 monthly searches for primary keyword |
| Forum activity | Reddit, Quora, niche forums | Active threads in last 90 days |
| Competitor content exists | SERP analysis | 3+ competitors publishing on topic |
| Social engagement | LinkedIn, X | Posts on topic get meaningful engagement |
| Reddit discussion depth | 11-Dimension analysis | At least 5 dimensions show active discussion |

### 2. Niche Validation

**Formula**: `Viability Score = (Demand × Buying Intent × (1 / Competition)) × Business Fit`

**Scoring each factor (1-5):**

**Demand** — Google Trends direction (↗/→/↘), Reddit activity (3+ active subreddits or 1 large 50K+), Whop marketplace (3+ active sellers = proven demand).

**Buying Intent** — High signals: Reddit "best [product] to buy", comparison queries, active Whop sales, affiliate programs exist, ads running. Low signals: only informational queries, no paid products, theoretical discussions.

**Competition (inverted — lower = higher score)** — SERP DA analysis: 5=DA<40, 4=DA 40-60, 3=DA 60-70, 2=DA 70-85, 1=DA 85+.

**Business Fit** — Monetization alignment: affiliates (easiest), info products $5-$27, courses/coaching $100-$5K, SaaS $10-$100/mo, services $500+.

**Niche Viability Scorecard:**

| Factor | Weight | Score (1-5) | Weighted | Notes |
|--------|--------|-------------|----------|-------|
| Demand | 30% | | | Google Trends + Reddit + Whop |
| Buying Intent | 30% | | | Commercial signals, price points |
| Competition (inverted) | 25% | | | Lower competition = higher score |
| Business Fit | 15% | | | Monetization alignment |
| **TOTAL** | **100%** | | | **Weighted average** |

**Decision thresholds:** 4.0+ = proceed with pillar + cluster strategy · 3.5-3.9 = start with 2-3 test pieces · 3.0-3.4 = only if Business Fit = 5 · 2.5-2.9 = deprioritise · <2.5 = skip.

**Q4 Seasonality Bonus:** Add +0.5 to Buying Intent score in Oct-Dec.

**Validation steps:**

1. Pull primary keyword + 10-20 related terms with volume and difficulty (see `seo/keyword-research.md`)
2. SERP analysis: assess top 10 results for DA, word count, content type, freshness, gaps
3. Content quality audit: read top 3 results — what they cover well, what they miss, depth, freshness, format gaps
4. Business alignment: map the funnel: Awareness ("what is [topic]") → Consideration ("best [topic] tools") → Decision ("[your product] for [topic]")

### 3. Competitor Content Analysis

**Competitor identification:** Search primary keyword (positions 1-10), check `context/competitor-analysis.md`, identify 3-5 direct competitors.

```markdown
## Competitor: [Name] ([domain.com])

- **Publishing frequency**: [X posts/month]
- **Primary topics**: [top 3-5 clusters]
- **Content types**: [blog, video, podcast, tools, templates]
- **Average word count**: [X words]
- **Estimated organic traffic**: [if available]
- **Strengths**: [what they do well]
- **Weaknesses**: [what they miss or do poorly]
- **Content Gaps We Can Exploit**: [topics, angles, formats, audience segments they miss]
```

**Competitor content matrix:**

| Topic | Us | Competitor A | Competitor B | Competitor C | Gap? |
|-------|-----|-------------|-------------|-------------|------|
| [topic] | [status] | [status] | [status] | [status] | [Y/N] |

Status: `none`, `thin` (<500 words), `basic` (500-1500), `comprehensive` (1500+), `pillar` (3000+)

### 4. Research Brief Output

```markdown
# Content Research Brief: [Topic/Niche]

**Date**: [YYYY-MM-DD]  **Researcher**: [agent/human]  **Niche score**: [X.X/5.0]

## Audience
[Audience profile from step 1]

## Niche Viability
[Scorecard from step 2]

## Keyword Targets
| Keyword | Volume | Difficulty | Intent | Priority |
|---------|--------|------------|--------|----------|
| [primary] | [vol] | [diff] | [intent] | P0 |

## Competitor Landscape
[Summary from step 3]

## Content Opportunities
1. [Highest-priority gap with rationale]
2. [Second gap]
3. [Third gap]

## Recommended Content Plan
| Priority | Title | Type | Target Keyword | Word Count | Funnel Stage |
|----------|-------|------|----------------|------------|--------------|
| P0 | [title] | [pillar/cluster/satellite] | [keyword] | [count] | [stage] |

## Next Steps
- [ ] Populate `context/target-keywords.md`
- [ ] Update `context/competitor-analysis.md`
- [ ] Add topics to content calendar
- [ ] Brief writer with this research for first article
```

## Storing Research

Save to the project's `context/` directory (see `content/context-templates.md`):

- `context/audience-profiles.md` — audience segments and personas
- `context/competitor-analysis.md` — competitor content matrix
- `context/target-keywords.md` — validated keyword targets
- `context/niche-scorecards.md` — niche validation results

These files are read automatically by `content/seo-writer.md` and `content/editor.md`.

## Integration

- **Feeds into**: `content/seo-writer.md`, `tools/content/content-calendar.md`, `content/context-templates.md`
- **Uses data from**: `seo/dataforseo.md`, `seo/google-search-console.md`, `seo/keyword-research.md`
- **Related**: `research.md` (general research agent), `seo/content-analyzer.md` (post-writing analysis)

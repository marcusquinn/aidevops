---
name: optimization
description: A/B testing, variant generation, analytics loops, and content performance optimization
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

# Content Optimization

Data-driven content improvement through systematic testing, variant generation, and analytics feedback loops.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Optimize content via A/B testing, variant generation, and analytics-driven iteration
- **Input**: Published content, performance metrics, test hypotheses
- **Output**: Winning variants, optimization recommendations, analytics insights
- **Related**: `content/production-*.md` (variants), `content/distribution-*.md` (platform metrics), `content/research.md` (next cycle)
- **Core rules**: 10+ variants before committing | 250+ samples before judging | <2% = kill | 2-3% = scale | >3% = go aggressive | Proven first, original second

<!-- AI-CONTEXT-END -->

## A/B Testing Discipline

### Testing Thresholds

| Metric | Threshold | Action |
|--------|-----------|--------|
| Variants tested | 10+ | Required before declaring winner |
| Sample size | 250+ | Minimum views/impressions per variant |
| Performance | <2% | Kill — redirect effort |
| Performance | 2-3% | Scale — produce more |
| Performance | >3% | Go aggressive — winner |

**Platform minimums**: YouTube: 250 impressions, 2% CTR, 50% retention | TikTok: 500 views, 70% completion | Blog: 100 visitors, 2min+ avg | Email: 250 sends, 20% open | Thumbnail: 1000 impressions, 5% CTR

**Statistical significance**: 95% confidence minimum; 7+ days for day-of-week variance; 14+ days for audiences <1000.

### What to Test (priority order)

1. **Hooks** (first 3s / headline / thumbnail) — 80% of performance variance
2. **Angles** (pain vs aspiration, contrarian vs consensus, before/after)
3. **Format** (long vs short, video vs text, listicle vs narrative)
4. **Thumbnails** (faces vs text, color, composition)
5. **CTAs** (placement, wording, urgency)
6. **Length** (word count, duration, scene count)
7. **Publishing time** (day, time)

**Hook types** (generate 5-10 per topic): Bold Claim, Question, Story, Contrarian, Result, Problem-Agitate, Curiosity Gap. Example: "95% of AI influencers fail — here's why" | "I spent $10K on AI video tools — here's what worked" | "Stop using Sora for UGC content"

**Thumbnail pipeline** (`thumbnail-helper.sh`):

```bash
thumbnail-helper.sh generate "Your Video Topic" --count 10 --template high-contrast-face
thumbnail-helper.sh batch-score ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh ab-test VIDEO_ID ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh analyze VIDEO_ID
```

### Test Execution Workflow

1. **Generate**: 10+ variants via `content/production-*.md` agents
2. **Deploy**: Platform-specific (YouTube A/B, TikTok separate videos, Google Optimize for blog, email list split)
3. **Collect**: 250+ samples per variant (CTR, retention, completion, time on page)
4. **Analyze**: Lift = `(variant - baseline) / baseline * 100`; check 95% significance
5. **Scale winners**: Extract pattern, store (`/remember "Hook pattern: ..."`), apply to next 10 pieces
6. **Batch cycle**: Week 1 produce → Week 2 collect → Week 3 analyze + kill bottom 7 → Week 4 produce from top 3

## Variant Generation

**Hook variants**: Generate 10 per topic using all 7 types, 6-12 words each. Prompt: `Generate 10 hook variants for topic: [topic]. Use all 7 hook types, 6-12 words each. Output as table: Type | Hook | Word Count`

**Seed bracketing** (see `content/production-video.md`): Ranges — People 1000-1999, Action 2000-2999, Landscape 3000-3999, Product 4000-4999. Test 10 outputs; score: Composition 30%, Quality 30%, Style 20%, Accuracy 20%. Threshold: 4.0+ winner, 3.0-3.9 maybe, <3.0 reject. Cuts AI video costs ~60% (15% → 70%+ success).

**Scene-level testing**: Publish → analyze YouTube Studio retention curve → identify >10% drops in <5s → generate 3-5 scene variants (B-roll, pacing, music, angle) → re-upload → compare → scale winner.

**Thumbnail scoring**: CTR 50%, Text readability 20%, Face prominence 15%, Contrast 10%, Emotion 5%. Style template (Nanobanana Pro JSON): define palette/font/composition/lighting, swap subject, keep style constant. Test 10 thumbnails across 10 videos at 1000+ impressions.

## Analytics — Platform Metrics & Thresholds

| Platform | Metric | Bad | Good | Great | Action |
|----------|--------|-----|------|-------|--------|
| YouTube | CTR | <2% | 2-5% | >5% | Test thumbnails/titles → scale → replicate |
| YouTube | Retention | <30% | 30-50% | >50% | Test hooks → optimize pacing → replicate format |
| TikTok/Reels/Shorts | Completion | <50% | 50-70% | >70% | Fix hook → optimize → replicate |
| TikTok/Reels/Shorts | Shares | — | — | >3% | Viral potential — go aggressive |
| TikTok/Reels/Shorts | Saves | — | — | >5% | High value — make more |
| Blog/SEO | Time on page | <1min | 1-3min | >3min | Content thin → decent → resonates |
| Blog/SEO | Scroll depth | <50% | — | >50% | Hook failed or too long |
| Blog/SEO | Bounce rate | >70% | — | <70% | Wrong audience or poor hook |
| Email | Open rate | <15% | 15-25% | >25% | Test subject lines → good → replicate |
| Email | Click rate | <2% | 2-5% | >5% | CTA failed → decent → offer works |

### Retention Analysis

1. Export: YouTube Studio → Analytics → Retention → Export CSV
2. Identify >10% drops in <5s
3. Categorize: Hook failure (0:00-0:10), Pacing issue (gradual), Scene failure (sharp), Natural exit (gradual at end)
4. Hypothesize → test fixes → compare retention

### Content Calendar

```bash
content-calendar-helper.sh cadence --weeks 1    # last week performance
content-calendar-helper.sh gaps --days 7        # missing next week
content-calendar-helper.sh due --days 7         # upcoming
content-calendar-helper.sh stats                # overall health
```

**Cadence**: YouTube 2-3/week (algorithm favors consistency) | Shorts/TikTok/Reels daily (volume finds viral) | Blog 1-2/week (SEO favors depth) | Email 1/week (avoid fatigue) | Social daily (engagement requires presence)

**Seasonality**: Q4 (Oct-Dec) highest buying intent → reviews, comparisons, affiliate. Q1 educational/how-to. Q2-Q3 experiment + build backlog.

### Feedback Loop

Publish → Collect analytics → Analyze → Extract patterns → Store (`/remember "Pattern: ..."`) → Feed research cycle → Inform next plan → repeat.

## Proven First, Original Second

1. Find proven content: top YouTube videos, viral TikToks, high-traffic posts (Ahrefs/SEMrush)
2. Replicate structure (same hook type, different topic) — copy format, not content
3. Add 3% twist: different personality, visual style, examples, or contrarian take
4. Test 10 variants with different twists → scale winner

Example: "I spent $10K testing every AI video tool" (1M views) → twist: "free ones that beat paid" / "why I refunded 90%"

## Tools & Automation

**Analytics**: YouTube Studio, TikTok Analytics, Google Analytics, Google Search Console (`seo/google-search-console.md`), DataForSEO (`seo/dataforseo.md`)

**A/B testing**: YouTube Studio (thumbnails), Google Optimize (website), VWO, Optimizely

**Scripts**: `content-calendar-helper.sh` (calendar/cadence/gaps, t208) | `analytics-helper.sh` (cross-platform reports) | `variant-generator-helper.sh` (10 variants) | `seed-bracket-helper.sh` (AI video seed testing) | `thumbnail-factory-helper.sh` (thumbnail variants, t207)

## Integration & Next Steps

**Feeds into**: `content/research.md` (next research), `content/production-*.md` (next batch). **Uses from**: `content/distribution-*.md` (analytics), `content/production-*.md` (variants). **Related**: `tools/task-management/beads.md`, `reference/memory.md`.

**After optimization**: Store winners (`/remember "Pattern: ..."`), update calendar to prioritize what works, feed winning topics into research cycle, scale with 10 more pieces using winning patterns.

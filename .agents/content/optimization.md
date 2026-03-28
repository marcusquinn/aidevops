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

- **Purpose**: Optimize content performance through A/B testing, variant generation, and analytics-driven iteration
- **Input**: Published content, performance metrics, test hypotheses
- **Output**: Winning variants, optimization recommendations, analytics insights
- **Related**: `content/production/` (generates test variants), `content/distribution/` (platform-specific metrics), `content/research.md` (feeds next cycle)

**Key Principles**:
- **10 variants minimum** before committing to an approach
- **250-sample rule** before judging performance
- **Below 2% = kill**, **above 2% = scale**, **above 3% = go aggressive**
- **Proven first, original second** — iterate on winners, not losers

<!-- AI-CONTEXT-END -->

## A/B Testing Discipline

### Testing Rules

| Metric | Threshold | Action |
|--------|-----------|--------|
| Variants tested | 10+ | Required before declaring a winner |
| Sample size | 250+ | Minimum views/impressions per variant |
| Performance threshold | <2% | Kill — redirect effort elsewhere |
| Performance threshold | 2-3% | Scale — produce more of this type |
| Performance threshold | >3% | Go aggressive — this is a winner |

**Sample size by platform**:

| Platform | Metric | Minimum Sample | Confidence Threshold |
|----------|--------|----------------|---------------------|
| YouTube | CTR + Retention | 250 impressions | 2% CTR, 50% retention |
| TikTok | Completion rate | 500 views | 70% completion |
| Blog | Time on page | 100 visitors | 2min+ average |
| Email | Open rate | 250 sends | 20% open rate |
| Thumbnail | CTR | 1000 impressions | 5% CTR |

**Statistical significance**: 95% confidence minimum; run 7+ days to account for day-of-week variance; 14+ days for audiences <1000.

### What to Test (priority order)

1. **Hooks** (first 3 seconds, headline, thumbnail) — 80% of performance variance
2. **Angles** (pain vs aspiration, contrarian vs consensus, before/after)
3. **Format** (long-form vs short-form, video vs text, listicle vs narrative)
4. **Thumbnails** (faces vs text, color schemes, composition)
5. **CTAs** (placement, wording, urgency)
6. **Length** (word count, video duration, scene count)
7. **Publishing time** (day of week, time of day)

**Hook types to test** (generate 5-10 per topic):
- Bold Claim: "95% of AI influencers fail — here's why"
- Question: "Why do most AI videos get ignored?"
- Story: "I spent $10K on AI video tools — here's what actually worked"
- Contrarian: "Stop using Sora for UGC content"
- Result: "From 0 to 100K views in 30 days with AI video"
- Problem-Agitate: "Your AI videos look fake — and everyone can tell"
- Curiosity Gap: "The one AI video trick nobody talks about"

**Thumbnail pipeline** (via `thumbnail-helper.sh`):

```bash
thumbnail-helper.sh generate "Your Video Topic" --count 10 --template high-contrast-face
thumbnail-helper.sh batch-score ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh ab-test VIDEO_ID ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh analyze VIDEO_ID
```

### Test Execution Workflow

1. **Generate variants**: 10+ versions using `content/production/` agents
2. **Deploy**: Platform-specific (YouTube A/B test, TikTok separate videos, Google Optimize for blog, email list split)
3. **Collect**: 250+ samples per variant (CTR, retention, completion rate, time on page)
4. **Analyze**: Calculate lift `(variant - baseline) / baseline * 100`; check 95% significance
5. **Scale winners**: Extract the pattern, store in memory (`/remember "Hook pattern: ..."`), apply to next 10 pieces
6. **Batch test**: Deploy 10 variants simultaneously (Week 1: produce, Week 2: collect, Week 3: analyze+kill bottom 7, Week 4: produce from top 3 patterns)

## Variant Generation

### Hook Variants

Generate 10 hooks per topic using all 7 types, 6-12 words each:

```text
Generate 10 hook variants for topic: [topic]
Use all 7 hook types, 6-12 words each
Output as table: Type | Hook | Word Count
```

### Seed Bracketing for Video

Systematically test seed ranges before committing to full production (see `content/production/video.md` for full details):

- **Seed ranges by content type**: People 1000-1999, Action 2000-2999, Landscape 3000-3999, Product 4000-4999
- **Test bracket**: Generate 10 outputs with seeds 2000-2010; score on Composition (30%), Quality (30%), Style (20%), Accuracy (20%)
- **Threshold**: 4.0+ = winner, 3.0-3.9 = maybe, <3.0 = reject
- **Efficiency gain**: Cuts AI video costs ~60% (success rate 15% → 70%+)

### Scene-Level Variant Testing

1. Publish video → analyze YouTube Studio retention curve
2. Identify drop-off points (>10% drop in 5 seconds) → isolate scene
3. Generate 3-5 variants (different B-roll, pacing, music, angle)
4. Re-upload as new video → compare retention → scale winner

### Thumbnail Variant Factory

Style template (Nanobanana Pro JSON): define color palette, font, composition, lighting. Swap subject/concept, keep style constant. Test 10 thumbnails across 10 videos; measure CTR at 1000+ impressions.

| Criterion | Weight |
|-----------|--------|
| CTR | 50% |
| Text readability | 20% |
| Face prominence | 15% |
| Contrast | 10% |
| Emotion | 5% |

## Analytics Loops

### Platform-Specific Metrics

**YouTube**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| CTR | <2% | Test new thumbnails/titles |
| CTR | 2-5% | Good — scale this format |
| CTR | >5% | Excellent — replicate pattern |
| Retention | <30% | Hook failed — test new hooks |
| Retention | 30-50% | Decent — optimize pacing |
| Retention | >50% | Great — this format works |

**TikTok/Reels/Shorts**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Completion rate | <50% | Hook failed |
| Completion rate | 50-70% | Decent — optimize pacing |
| Completion rate | >70% | Winner — replicate format |
| Shares | >3% | Viral potential — go aggressive |
| Saves | >5% | High value — make more like this |

**Blog/SEO**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Time on page | <1min | Content too thin or wrong audience |
| Time on page | >3min | Great — this topic resonates |
| Scroll depth | <50% | Hook failed or content too long |
| Bounce rate | >70% | Wrong audience or poor hook |

**Email**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Open rate | <15% | Test new subject lines |
| Open rate | >25% | Excellent — replicate pattern |
| Click rate | <2% | CTA failed |
| Click rate | >5% | Great — this offer works |

### Retention Analysis Workflow

1. Export retention curve: YouTube Studio → Analytics → Retention → Export CSV
2. Identify drop-off points (>10% drop in <5 seconds)
3. Categorize: Hook failure (0:00-0:10), Pacing issue (gradual), Scene failure (sharp drop), Natural exit (gradual at end)
4. Generate hypotheses → test fixes → compare retention

### Content Calendar Integration

```bash
content-calendar-helper.sh cadence --weeks 1    # last week performance
content-calendar-helper.sh gaps --days 7        # missing next week
content-calendar-helper.sh due --days 7         # upcoming
content-calendar-helper.sh stats                # overall health
```

**Posting cadence**:

| Platform | Frequency | Rationale |
|----------|-----------|-----------|
| YouTube | 2-3/week | Algorithm favors consistency |
| Shorts/TikTok/Reels | Daily | High volume needed to find viral hits |
| Blog | 1-2/week | SEO favors depth over frequency |
| Email | 1/week | Avoid list fatigue |
| Social (X, LinkedIn) | Daily | Engagement requires presence |

**Seasonality**: Q4 (Oct-Dec) = highest buying intent → product reviews, comparisons, affiliate content. Q1 = educational/how-to. Q2-Q3 = experiment with new formats, build backlog.

### Analytics Feedback Loop

Publish → Collect analytics → Analyze → Extract patterns → Store in memory (`/remember "Pattern: ..."`) → Feed into research cycle → Inform next content plan → repeat.

## Proven First, Original Second

1. **Find proven content**: Top 10 YouTube videos, viral TikToks, high-traffic blog posts (Ahrefs/SEMrush)
2. **Replicate structure**: Copy format, not content (same hook type, different topic)
3. **Add 3% twist**: Different personality, visual style, examples, or contrarian take
4. **Test 10 variants** with different twists → scale the winner

Example: "I spent $10K testing every AI video tool" (1M views) → replicate structure → twist: "here's the free ones that beat the paid ones" / "here's why I refunded 90%"

## Tools and Automation

**Analytics**: YouTube Studio, TikTok Analytics, Google Analytics, Google Search Console (`seo/google-search-console.md`), DataForSEO (`seo/dataforseo.md`)

**A/B testing**: YouTube Studio (thumbnails), Google Optimize (website), VWO, Optimizely

**Automation scripts**:
- `content-calendar-helper.sh`: calendar, cadence tracking, gap analysis (t208)
- `analytics-helper.sh`: pull analytics from all platforms, generate report
- `variant-generator-helper.sh`: generate 10 variants of a piece of content
- `seed-bracket-helper.sh`: automate seed testing for AI video generation
- `thumbnail-factory-helper.sh`: generate thumbnail variants using style library (t207)

## Integration

- **Feeds into**: `content/research.md` (analytics inform next research cycle), `content/production/` (winning patterns inform next batch)
- **Uses data from**: `content/distribution/` (platform analytics), `content/production/` (variant generation)
- **Related**: `tools/task-management/beads.md` (task tracking), `reference/memory.md` (pattern storage)

## Next Steps

1. Store winning patterns: `/remember "Pattern: [description]"`
2. Update content calendar: prioritize more of what works
3. Feed into research cycle: use winning topics as seeds
4. Scale production: produce 10 more pieces using winning patterns

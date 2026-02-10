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

Systematic testing methodology to identify winning content patterns before scaling production.

### Testing Rules

**Minimum viable test**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Variants tested | 10+ | Required before declaring a winner |
| Sample size | 250+ | Minimum views/impressions per variant |
| Performance threshold | <2% | Kill — redirect effort elsewhere |
| Performance threshold | 2-3% | Scale — produce more of this type |
| Performance threshold | >3% | Go aggressive — this is a winner |

**Sample size requirements by platform**:

| Platform | Metric | Minimum Sample | Confidence Threshold |
|----------|--------|----------------|---------------------|
| YouTube | CTR + Retention | 250 impressions | 2% CTR, 50% retention |
| TikTok | Completion rate | 500 views | 70% completion |
| Blog | Time on page | 100 visitors | 2min+ average |
| Email | Open rate | 250 sends | 20% open rate |
| Thumbnail | CTR | 1000 impressions | 5% CTR |

**Statistical significance**:

- Use A/B testing tools with built-in significance calculators (Google Optimize, VWO, Optimizely)
- Minimum 95% confidence level before declaring a winner
- Run tests for at least 7 days to account for day-of-week variance
- For small audiences (<1000), extend test duration to 14+ days

### What to Test

**Priority order** (highest impact first):

1. **Hooks** (first 3 seconds, headline, thumbnail) — 80% of performance variance
2. **Angles** (pain vs aspiration, contrarian vs consensus, before/after)
3. **Format** (long-form vs short-form, video vs text, listicle vs narrative)
4. **Thumbnails** (faces vs text, color schemes, composition)
5. **CTAs** (placement, wording, urgency)
6. **Length** (word count, video duration, scene count)
7. **Publishing time** (day of week, time of day)

**Hook testing framework**:

Generate 5-10 hook variants per topic before committing to production. Test across:

- **Bold Claim**: "95% of AI influencers fail — here's why"
- **Question**: "Why do most AI videos get ignored?"
- **Story**: "I spent $10K on AI video tools — here's what actually worked"
- **Contrarian**: "Stop using Sora for UGC content"
- **Result**: "From 0 to 100K views in 30 days with AI video"
- **Problem-Agitate**: "Your AI videos look fake — and everyone can tell"
- **Curiosity Gap**: "The one AI video trick nobody talks about"

**Thumbnail testing**:

- Generate 5-10 thumbnail variants using style library templates (see `content/production/image.md`)
- Test via YouTube's built-in A/B testing or manual rotation
- Score on: text readability, face prominence, contrast, emotion
- Winning thumbnail style becomes template for next 10 videos

### Test Execution

**Rapid testing workflow**:

1. **Generate variants**: Use `content/production/` agents to create 10+ versions
   - Hook variants: `content/story.md` frameworks
   - Thumbnail variants: `content/production/image.md` style library
   - Script variants: `content/production/writing.md` structure templates
   - Video variants: `content/production/video.md` seed bracketing

2. **Deploy test**: Platform-specific deployment
   - **YouTube**: Upload with different thumbnails, rotate via YouTube Studio A/B test
   - **TikTok/Reels**: Post variants as separate videos, measure completion rate
   - **Blog**: Use Google Optimize or VWO for headline/intro A/B tests
   - **Email**: Split list into segments, test subject lines

3. **Collect data**: Minimum 250 samples per variant
   - YouTube: CTR, retention curve, watch time
   - TikTok: Completion rate, shares, saves
   - Blog: Time on page, scroll depth, bounce rate
   - Email: Open rate, click rate, conversion rate

4. **Analyze results**: Compare against baseline and thresholds
   - Calculate lift: `(variant - baseline) / baseline * 100`
   - Check statistical significance (95% confidence)
   - Identify winning patterns (not just winning variants)

5. **Scale winners**: Produce more content using winning patterns
   - Extract the pattern (e.g., "question hooks outperform bold claims 2:1")
   - Store pattern in memory: `/remember "Hook pattern: question format gets 2x CTR vs bold claims for [niche]"`
   - Apply pattern to next 10 pieces of content

**Batch testing for efficiency**:

Instead of testing one piece at a time, batch test 10 variants simultaneously:

- **Week 1**: Produce 10 hook variants, deploy all
- **Week 2**: Collect data (250+ samples each)
- **Week 3**: Analyze, kill bottom 7, scale top 3
- **Week 4**: Produce 10 new variants using top 3 patterns

This approach finds winners 10x faster than sequential testing.

## Variant Generation

Systematic creation of test variants across all content dimensions.

### Hook Variant Generation

**Process**:

1. Start with core topic: "AI video generation for content creators"
2. Generate 10 hook variants using 7 hook types (see `content/story.md`)
3. Constraint: 6-12 words maximum
4. Test all 10, measure CTR/retention
5. Scale top 3 patterns

**Example hook variants for "AI video generation"**:

| Type | Hook | Word Count |
|------|------|------------|
| Bold Claim | "AI video will replace 90% of editors" | 8 |
| Question | "Why do AI videos still look fake?" | 7 |
| Story | "I spent $10K testing every AI video tool" | 8 |
| Contrarian | "Stop using Sora for social media content" | 7 |
| Result | "0 to 100K views with AI video in 30 days" | 10 |
| Problem-Agitate | "Your AI videos scream 'AI' — here's why" | 8 |
| Curiosity Gap | "The AI video secret nobody shares" | 6 |
| Bold Claim 2 | "Veo 3.1 just killed the video production industry" | 8 |
| Question 2 | "Can AI video actually look cinematic?" | 6 |
| Result 2 | "From amateur to 100K subscribers with AI" | 7 |

**Automation**:

Use `content/story.md` agent with prompt:

```text
Generate 10 hook variants for topic: [topic]
Use all 7 hook types, 6-12 words each
Output as table: Type | Hook | Word Count
```

### Seed Bracketing for Video

**Purpose**: Systematically test seed ranges to find high-quality outputs before committing to full production.

**Method** (see `content/production/video.md` for full details):

1. **Define seed range** by content type:
   - People: 1000-1999
   - Action: 2000-2999
   - Landscape: 3000-3999
   - Product: 4000-4999
   - YouTube-optimized: 2000-3000

2. **Test bracket**: Generate 10 outputs with seeds 2000-2010
3. **Score outputs**: Use vision model to rate on:
   - Composition (rule of thirds, framing)
   - Quality (sharpness, artifacts, lighting)
   - Style consistency (matches brand aesthetic)
   - Subject accuracy (prompt adherence)

4. **Pick winners**: Top 3 seeds become production seeds
5. **Iterate**: If no winners, shift range (2010-2020) and repeat

**Scoring rubric**:

| Dimension | Weight | 1 (Poor) | 3 (Good) | 5 (Excellent) |
|-----------|--------|----------|----------|---------------|
| Composition | 30% | Off-center, poor framing | Decent framing | Rule of thirds, cinematic |
| Quality | 30% | Artifacts, blurry | Clean, sharp | Pristine, 4K-ready |
| Style | 20% | Generic, off-brand | Matches style | Perfect brand fit |
| Accuracy | 20% | Wrong subject | Close to prompt | Exact prompt match |

**Total score**: Weighted average. Threshold: 4.0+ = winner, 3.0-3.9 = maybe, <3.0 = reject.

**Efficiency gain**: Seed bracketing cuts AI video costs by ~60% (success rate 15% → 70%+).

### Scene-Level Variant Testing

**Purpose**: Identify which specific moments in a video cause retention drop-off.

**Process**:

1. **Publish video** with analytics enabled (YouTube Studio retention curve)
2. **Analyze retention curve**: Identify drop-off points (>10% drop in 5 seconds)
3. **Isolate scenes**: Which scene caused the drop? (B-roll, talking head, transition)
4. **Generate variants**: Re-render that scene with 3-5 different approaches
   - Different B-roll footage
   - Different pacing (faster cuts)
   - Different music/SFX
   - Different camera angle
5. **Re-upload as new video**: Test variant, compare retention curve
6. **Scale winner**: Use winning scene pattern in next 10 videos

**Example**:

- Original video: Retention drops 15% at 0:45 (during product demo scene)
- Hypothesis: Demo is too slow, viewers lose interest
- Variants:
  - A: Same demo, 2x speed
  - B: Same demo, add text overlays with key points
  - C: Replace demo with before/after comparison
- Test: Upload 3 new videos with variants A, B, C
- Result: Variant C (before/after) retains 12% better
- Action: Use before/after format for all future product demos

### Thumbnail Variant Factory

**Purpose**: Generate consistent, on-brand thumbnail variants at scale.

**Process** (see `content/production/image.md` for full details):

1. **Define style template**: Nanobanana Pro JSON with brand constants
   - Color palette: `["#FF6B35", "#004E89", "#FFFFFF"]`
   - Font: `"Montserrat Bold"`
   - Composition: `"Rule of thirds, subject left, text right"`
   - Lighting: `"High contrast, dramatic shadows"`

2. **Generate variants**: Swap subject/concept, keep style constant
   - Template: `{"style": "editorial", "subject": "[VARIABLE]", "composition": "rule_of_thirds", "colors": ["#FF6B35", "#004E89"]}`
   - Variant 1: `subject = "shocked face"`
   - Variant 2: `subject = "before/after split"`
   - Variant 3: `subject = "product close-up"`

3. **Test batch**: Upload 10 videos with 10 different thumbnails
4. **Measure CTR**: YouTube Studio analytics, 1000+ impressions per thumbnail
5. **Scale winner**: Winning subject type becomes default for next batch

**Thumbnail scoring criteria**:

| Criterion | Weight | Measurement |
|-----------|--------|-------------|
| CTR | 50% | YouTube Studio analytics |
| Text readability | 20% | Can you read text in 0.5 seconds? |
| Face prominence | 15% | Is face >30% of frame? |
| Contrast | 10% | Does it stand out in feed? |
| Emotion | 5% | Does face show clear emotion? |

**Automation**:

```bash
# Generate 10 thumbnail variants
for i in {1..10}; do
  # Use Nanobanana Pro JSON template with different subjects
  # See content/production/image.md for JSON schema
done
```

## Analytics Loops

Continuous feedback from performance data into content strategy and production.

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
| Watch time | <2min | Too long or boring — cut length |
| Watch time | 2-5min | Good for short-form |
| Watch time | >5min | Great for long-form |

**TikTok/Reels/Shorts**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Completion rate | <50% | Hook failed — test new hooks |
| Completion rate | 50-70% | Decent — optimize pacing |
| Completion rate | >70% | Winner — replicate format |
| Shares | <1% | Not shareable — add value/emotion |
| Shares | 1-3% | Good — scale this type |
| Shares | >3% | Viral potential — go aggressive |
| Saves | <2% | Not useful — add actionable tips |
| Saves | 2-5% | Good — educational content works |
| Saves | >5% | High value — make more like this |

**Blog/SEO**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Time on page | <1min | Content too thin or wrong audience |
| Time on page | 1-3min | Decent — optimize for engagement |
| Time on page | >3min | Great — this topic resonates |
| Scroll depth | <50% | Hook failed or content too long |
| Scroll depth | 50-75% | Good — optimize lower sections |
| Scroll depth | >75% | Excellent — readers engaged |
| Bounce rate | >70% | Wrong audience or poor hook |
| Bounce rate | 40-70% | Normal — optimize CTAs |
| Bounce rate | <40% | Great — readers exploring site |

**Email**:

| Metric | Threshold | Action |
|--------|-----------|--------|
| Open rate | <15% | Test new subject lines |
| Open rate | 15-25% | Good — scale this format |
| Open rate | >25% | Excellent — replicate pattern |
| Click rate | <2% | CTA failed — test new CTAs |
| Click rate | 2-5% | Good — optimize landing page |
| Click rate | >5% | Great — this offer works |

### Retention Analysis Workflow

**Purpose**: Identify exactly which moments in a video retain vs cause drop-off.

**Process**:

1. **Export retention curve**: YouTube Studio → Analytics → Retention → Export CSV
2. **Identify drop-off points**: >10% drop in <5 seconds
3. **Map to timeline**: Which scene/moment caused the drop?
4. **Categorize drop-offs**:
   - **Hook failure**: Drop in first 10 seconds (0:00-0:10)
   - **Pacing issue**: Gradual decline (slow content, no payoff)
   - **Scene failure**: Sharp drop at specific moment (boring B-roll, long explanation)
   - **Natural exit**: Gradual decline at end (viewers got value, left satisfied)

5. **Generate hypotheses**: Why did viewers leave?
   - Hook: Not compelling enough, didn't deliver on promise
   - Pacing: Too slow, too fast, repetitive
   - Scene: Boring visuals, confusing explanation, off-topic tangent

6. **Test fixes**: Create variant with improved scene, re-upload, compare retention

**Example retention analysis**:

```text
Video: "How to Use AI Video for Content Creation"
Total views: 5,000
Average retention: 42%

Drop-off points:
- 0:03 (15% drop): Hook didn't grab attention
- 0:45 (12% drop): Slow product demo scene
- 2:30 (10% drop): Long technical explanation

Actions:
- Test 5 new hook variants (see Hook Variant Generation)
- Replace demo with before/after comparison (see Scene-Level Variant Testing)
- Cut technical explanation from 60s to 20s, add visual examples
```

### Content Calendar Integration

**Purpose**: Use analytics feedback to inform next cycle's topic selection and production priorities.

**Workflow**:

1. **Weekly review**: Analyze performance of all published content from past 7 days
2. **Identify patterns**: Which topics/formats/angles performed best?
3. **Update content calendar**: Prioritize more of what works, deprioritize what doesn't
4. **Store patterns in memory**: `/remember "Pattern: [niche] + [format] gets [X]% better retention than baseline"`
5. **Feed into research cycle**: Use winning topics as seeds for next research phase (see `content/research.md`)

**Content calendar template**:

| Week | Topic | Format | Platform | Status | Performance | Next Action |
|------|-------|--------|----------|--------|-------------|-------------|
| W1 | AI video tools | Long-form | YouTube | Published | 3.2% CTR, 48% retention | Scale — make 3 more |
| W1 | Sora 2 tutorial | Short-form | TikTok | Published | 65% completion | Good — test new hook |
| W2 | Veo 3.1 review | Long-form | YouTube | Planned | - | Use winning hook pattern |
| W2 | AI video mistakes | Short-form | Reels | Planned | - | Use before/after format |

**Posting cadence recommendations**:

| Platform | Frequency | Rationale |
|----------|-----------|-----------|
| YouTube | 2-3/week | Algorithm favors consistency, not volume |
| Shorts/TikTok/Reels | Daily | High volume needed to find viral hits |
| Blog | 1-2/week | SEO favors depth over frequency |
| Email | 1/week | Avoid list fatigue |
| Social (X, LinkedIn) | Daily | Engagement requires presence |

**Q4 seasonality awareness**:

- **Q4 (Oct-Dec)**: Highest buying intent — prioritize monetization-focused content
  - Product reviews, comparisons, "best of" lists
  - Affiliate content, info product launches
  - Holiday gift guides, year-end roundups

- **Q1 (Jan-Mar)**: New Year motivation — prioritize educational content
  - "How to get started" guides, beginner tutorials
  - Goal-setting, planning, strategy content

- **Q2-Q3 (Apr-Sep)**: Maintenance mode — test new formats, build backlog
  - Experiment with new topics, formats, platforms
  - Build content backlog for Q4 push

### Analytics Feedback Loop

**Purpose**: Close the loop from performance data back to research and strategy.

**Process**:

1. **Publish content** → 2. **Collect analytics** → 3. **Analyze performance** → 4. **Extract patterns** → 5. **Store in memory** → 6. **Feed into next research cycle** → 7. **Inform next content plan** → (repeat)

**Example loop**:

```text
Cycle 1:
- Research: "AI video generation" niche (see content/research.md)
- Produce: 10 videos on AI video tools
- Publish: YouTube, TikTok, Blog
- Analyze: "Sora 2 tutorial" got 2x CTR vs others
- Pattern: "Tool-specific tutorials outperform general overviews"
- Store: /remember "Pattern: [AI video niche] tool-specific tutorials get 2x CTR vs general content"

Cycle 2:
- Research: Recall pattern, research more tool-specific topics
- Produce: 10 videos on specific tools (Veo 3.1, Nanobanana, Higgsfield)
- Publish: YouTube, TikTok, Blog
- Analyze: "Veo 3.1 cinematic prompts" got 3x CTR
- Pattern: "Advanced technique tutorials outperform basic tutorials"
- Store: /remember "Pattern: [AI video niche] advanced techniques get 3x CTR vs basic tutorials"

Cycle 3:
- Research: Recall patterns, research advanced technique topics
- Produce: 10 videos on advanced techniques (seed bracketing, style libraries, prompt engineering)
- (continue loop)
```

**Automation**:

```bash
# Weekly analytics review script
# 1. Pull analytics from all platforms
# 2. Compare against baseline and thresholds
# 3. Generate performance report
# 4. Store winning patterns in memory
# 5. Update content calendar with next cycle's priorities
```

## Proven First, Original Second

**Philosophy**: Iterate on proven winners, not on losers.

**Strategy**:

1. **Find proven content**: Research what already works in your niche
   - Top 10 videos on YouTube for your topic
   - Viral TikToks in your niche
   - High-traffic blog posts (via Ahrefs, SEMrush)

2. **Replicate structure**: Copy the format, not the content
   - Same hook type, different topic
   - Same video structure, different examples
   - Same blog outline, different angle

3. **Add 3% twist**: Make it yours with a small unique element
   - Different personality/voice
   - Different visual style
   - Different examples/case studies
   - Contrarian take on same topic

4. **Test variants**: Generate 10 versions with different twists
5. **Scale winners**: Once you find your twist that works, produce 10 more

**Example**:

- **Proven**: "I spent $10K testing every AI video tool — here's what works" (1M views)
- **Replicate**: "I spent [X] testing every [category] — here's what works" structure
- **3% twist**: Your unique angle
  - "I spent 100 hours testing AI video tools — here's the free ones that beat the paid ones"
  - "I spent $10K on AI video tools — here's why I refunded 90% of them"
  - "I spent 6 months testing AI video tools — here's the only 3 you need"

**Why this works**:

- Proven content has already validated the market (demand exists)
- Proven content has already validated the format (structure works)
- Your twist differentiates you without reinventing the wheel
- Testing 10 twists finds your unique voice faster than starting from scratch

## Rapid Testing Framework

**Purpose**: Iterate faster by testing multiple variants in parallel.

**Components**:

1. **B-roll library**: Pre-generated stock footage, animations, transitions
2. **Voice clone**: Consistent narration voice across all variants
3. **Script variants**: 10 different scripts for same topic
4. **Thumbnail variants**: 10 different thumbnails for same video

**Workflow**:

1. **Week 1: Generate variants**
   - Write 10 script variants (see `content/production/writing.md`)
   - Generate 10 thumbnail variants (see `content/production/image.md`)
   - Record 10 voiceovers using voice clone (see `content/production/audio.md`)
   - Assemble 10 videos using B-roll library (see `content/production/video.md`)

2. **Week 2: Deploy and collect data**
   - Upload all 10 videos to YouTube (or TikTok, or blog)
   - Wait for 250+ impressions per variant
   - Collect CTR, retention, watch time data

3. **Week 3: Analyze and scale**
   - Identify top 3 performers
   - Extract winning patterns (hook type, thumbnail style, script structure)
   - Kill bottom 7 variants (unlist or delete)

4. **Week 4: Produce next batch**
   - Generate 10 new variants using top 3 patterns
   - Repeat cycle

**Efficiency gain**: This approach finds winners 4x faster than sequential testing (10 variants in 4 weeks vs 10 weeks).

## Integration

- **Feeds into**: `content/research.md` (analytics inform next research cycle), `content/production/` (winning patterns inform next production batch)
- **Uses data from**: `content/distribution/` (platform-specific analytics), `content/production/` (variant generation)
- **Related**: `tools/task-management/beads.md` (task tracking for test execution), `memory/README.md` (pattern storage)

## Tools and Automation

**Analytics tools**:

- **YouTube Studio**: Retention curves, CTR, watch time
- **TikTok Analytics**: Completion rate, shares, saves
- **Google Analytics**: Time on page, scroll depth, bounce rate
- **Google Search Console**: Click-through rate, impressions, rankings (see `seo/google-search-console.md`)
- **DataForSEO**: Keyword rankings, competitor analysis (see `seo/dataforseo.md`)

**A/B testing tools**:

- **YouTube Studio**: Built-in thumbnail A/B testing
- **Google Optimize**: Website headline/intro A/B testing
- **VWO**: Full-stack A/B testing platform
- **Optimizely**: Enterprise A/B testing

**Automation scripts**:

- `analytics-helper.sh`: Pull analytics from all platforms, generate performance report
- `variant-generator-helper.sh`: Generate 10 variants of a given piece of content
- `seed-bracketing-helper.sh`: Automate seed testing for AI video generation (see t202)
- `thumbnail-factory-helper.sh`: Generate thumbnail variants using style library (see t207)

## Next Steps

After optimizing content:

1. **Store winning patterns**: `/remember "Pattern: [description]"`
2. **Update content calendar**: Prioritize more of what works
3. **Feed into research cycle**: Use winning topics as seeds for next research phase
4. **Scale production**: Produce 10 more pieces using winning patterns
5. **Repeat loop**: Continuous optimization cycle

# Creative Testing Campaign (ABO)

> The testing campaign is where you discover what works. Every winning ad starts here.

## Purpose & Philosophy

**Why ABO?** CBO campaigns starve new creative — the algorithm favors proven performers. ABO gives each ad set its allocated budget regardless of performance, ensuring every creative gets a fair test.

**Testing mindset**: form hypotheses, test them, learn. 80% of creative won't work — that's normal. Let data decide, not feelings. Fast iteration beats perfect planning.

## Campaign Structure

```
Campaign: Creative Testing
├── Objective: Conversions (Purchases or Leads)
├── Budget Type: Ad Set Budget (ABO)
├── Advantage Campaign Budget: OFF
│
├── Ad Set 1: [Creative Angle A]  ← $30-100/day, broad audience, Advantage+ Placements, 1-2 ads
├── Ad Set 2: [Creative Angle B]  ← same setup
└── Ad Set 3: [Creative Angle C]  ← same setup
```

### Budget Per Ad Set

Aim for 50 conversions per ad set per week: `Budget = Target CPA × 50 ÷ 7`

| Target CPA | Min Daily Budget |
|------------|------------------|
| $10 | $50-75 |
| $25 | $75-125 |
| $50 | $150-250 |
| $100 | $300-500 |

Can't afford 50 conversions? Test with $30-50/day per ad set for 5-7 days — directional data, not statistical significance.

### Audience Selection

Use your scaling audience for testing (broad = minimal restrictions, 18-65+, target geography, no interest/behavior targeting, Advantage+ Audience ON). Results reflect what you'll see at scale; algorithm learns faster with more data.

### Ads Per Ad Set

**Optimal: 1-2 ads per ad set.** More ads = not enough data per ad.

- **1 ad per ad set**: clearest learning — winner is obvious
- **2 ads per ad set (recommended)**: same angle, different formats (video + static) — learn which format works per angle

Avoid: mixing different angles in same ad set, more than 3 ads per ad set, adding new ads to active ad sets.

**Placements**: use Advantage+ Placements. Exception: if testing a placement hypothesis (e.g., Reels-only), create a separate ad set.

## Testing Methodology

### What to Test (Priority Order)

| Tier | What | Impact |
|------|------|--------|
| 1 | Creative concept/angle (problem vs benefit, testimonial vs demo, UGC vs polished) | Highest |
| 2 | Hook (first 3s of video, first line of copy, opening visual) | High |
| 3 | Format (video vs static, carousel vs single, long vs short) | Medium |
| 4 | Copy elements (headlines, body length, CTA) | Medium |
| 5 | Visual elements (colors, fonts, minor design) | Lower |

### Variable Isolation

Test one thing at a time:

```
Bad:  Ad A: Video + Pain point + Long copy  /  Ad B: Static + Benefit + Short copy  → What won? Unknown.
Good: Ad A: Video + Pain point + Medium copy  /  Ad B: Video + Benefit + Medium copy → Benefit beats pain point.
```

### Dynamic Creative Testing (DCT)

Upload multiple assets; Meta tests combinations automatically.

| | DCT | Manual |
|-|-----|--------|
| Best for | High volume (100+ conv/day), many assets, optimization | Lower volume, clear learnings, concept testing |
| Downside | Can't see which combination worked ("black box") | More manual work |

### Sample Size Requirements

- **Statistical significance**: 50+ conversions per variation, 95% confidence, 7+ days
- **Directional guidance**: 20-30 conversions per variation, 3-5 days
- Calculator: ABTestGuide.com (enter baseline conversion rate and desired lift)

## Metrics & Decision Making

### Primary Metrics

| Objective | Primary Metrics |
|-----------|----------------|
| Purchases | CPA (at/below target), ROAS (at/above target), purchase volume |
| Leads | CPL (at/below target), lead quality (via CRM), lead volume |

### Secondary Diagnostic Metrics

| Metric | What It Tells You |
|--------|-------------------|
| CTR | Is the ad compelling enough to click? |
| Hook Rate (3s video) | Is the opening grabbing attention? |
| Hold Rate (15s video) | Is the content engaging? |
| ThruPlay Rate | Did they watch the full message? |
| CPM | Is the audience too competitive? |
| CPC | Is the ad relevant to clickers? |
| Landing Page Views | Are clicks turning into actual visits? |

### Diagnostic Framework

```
Low Conversions?
1. High CPM (>$20)?       → Audience or quality issue
2. Low CTR (<0.8%)?       → Creative not compelling
3. Clicks ≠ LPV?          → Page load issues
4. Low CVR (<5%)?         → Landing page or offer issue
```

### When to Kill an Ad

| Timeframe | Kill if |
|-----------|---------|
| Immediately | CTR <0.3% after 1,000+ impressions; zero conversions after 2× target CPA spend; Quality Ranking "Below Average (Bottom 20%)" |
| After 3-5 days | CPA 50%+ above target with 10+ conversions; CTR <0.5% sustained |
| After 7 days | CPA 25%+ above target with 30+ conversions; performance declining; better performers identified |

### When to Declare a Winner

**Criteria**: CPA at/below target for 3+ consecutive days, 50+ conversions (ideally 100+), CTR above 1%, stable or improving trend.

| Conversions | Confidence | Action |
|-------------|------------|--------|
| 20-50 | Directional | Proceed cautiously |
| 50-100 | Good | Move to scale |
| 100+ | High | Scale aggressively |

Don't react to Day 1 results (good or bad) — wait 3 days of consistent data. Inconsistent performance: check frequency (ad fatigue?) and external factors (weekend vs weekday).

## Testing Frameworks

### The "3-2-2" Method

3 ad sets (different angles) × 2 ads per ad set (same angle, different formats) × 2 weeks.
- Week 1: let all run, gather data
- Week 2: kill obvious losers
- After 2 weeks: identify winners, move to scale

### The "Rapid Fire" Method

5+ ad sets, 1 ad each, $30-50/day, 3-5 day tests. Best for early stage, many ideas, smaller budgets.
- Day 3: kill bottom 2
- Day 5: kill bottom 1-2 more
- Winners move to scale

### Concept vs Iteration Testing

**Concept testing** (big swings — find what resonates):
```
Ad Set 1: Testimonial UGC  /  Ad Set 2: Product demo  /  Ad Set 3: Founder talking head  /  Ad Set 4: Static comparison
```

**Iteration testing** (optimize a winning concept):
```
Ad Set 1: Testimonial - Hook A  /  Ad Set 2: Testimonial - Hook B  /  Ad Set 3: Testimonial - Hook C
```

Process: start with concept testing → find winning concept → move to iteration testing.

### Hook Testing Framework

First 3 seconds determine if someone watches. First line determines if someone reads.

| Category | Video Example | Text Example |
|----------|---------------|--------------|
| Curiosity | "Nobody talks about this..." | "The secret nobody talks about..." |
| Pain | "Tired of [problem]?" | "Still struggling with [problem]?" |
| Benefit | "[Result] in [timeframe]" | "How I got [result] in [timeframe]" |
| Controversy | "Unpopular opinion..." | "[Industry] is lying to you" |
| Story | "Last year I was [bad situation]..." | "I used to [struggle]..." |
| Social Proof | "How [Company] got [result]" | "[X] companies use this to..." |
| Question | "What if you could [desire]?" | "Ever wondered why [thing]?" |

Process: identify winning creative → create 3-5 hook variations → keep body the same → test head-to-head → winner hook + winner body = optimized ad.

After finding winning hook, test body elements (feature vs benefit focus, short vs detailed, social proof, urgency) and CTAs ("Shop Now" vs "Learn More", etc.). CTA impact: typically 5-20% lift.

## From Test to Scale

### Winner Checklist

- [ ] CPA at or below target for 3+ days
- [ ] 50+ conversions minimum
- [ ] CTR above 0.8% (ideally 1%+)
- [ ] Stable or improving trend
- [ ] Creative not fatigued (frequency <3)

### How to Move Winners

**Best practice**: duplicate the whole ad set to preserve learning history.

1. Go to winning ad set → Duplicate → Choose scale campaign → Turn on
2. Keep original running OR pause

After graduating: keep testing new concepts, test iterations of winner, test for different audiences (cold vs warm).

### Testing Velocity

| Spend Level | New Concepts/Week | New Iterations/Week |
|-------------|-------------------|---------------------|
| <$5K/mo | 2-3 | 2-3 |
| $5-20K/mo | 4-6 | 4-6 |
| $20-50K/mo | 6-10 | 6-10 |
| $50K+/mo | 10+ | 10+ |

**Rule of thumb**: 20% of budget should be testing new concepts.

## Testing Campaign Checklist

### Before Launching

- [ ] Objective = Conversions; ABO enabled (not CBO)
- [ ] Budget per ad set calculated; same audience across ad sets
- [ ] Advantage+ Placements on; 1-2 ads per ad set
- [ ] Testing one variable per test
- [ ] Pixel/CAPI configured; UTM parameters added

### Review Schedule

| Day | Action |
|-----|--------|
| Daily | Check spend vs budget, early metrics (CTR, CPM), no disapprovals |
| Day 3 | Kill obvious losers; check for technical issues |
| Day 7 | Kill underperformers; identify potential winners; plan next tests |
| Day 14 | Declare winners; move to scale; document learnings; plan iteration tests |

---

*Next: [Scaling Campaign (CBO)](scaling-cbo.md)*

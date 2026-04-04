<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Creative Testing Campaign (ABO)

## Purpose

**Why ABO?** CBO starves new creative — the algorithm favors proven performers. ABO gives each ad set its allocated budget regardless of performance, ensuring fair tests. Mindset: hypothesize, test, learn. 80% of creative won't work — that's normal. Fast iteration beats perfect planning.

## Campaign Structure

```text
Campaign: Creative Testing
├── Objective: Conversions (Purchases or Leads)
├── Budget Type: Ad Set Budget (ABO), Advantage Campaign Budget: OFF
├── Ad Set 1: [Angle A]  ← $30-100/day, broad audience, Advantage+ Placements, 1-2 ads
├── Ad Set 2: [Angle B]  ← same setup
└── Ad Set 3: [Angle C]  ← same setup
```

**Budget/ad set:** Target 50 conv/ad set/week: `Budget = Target CPA × 50 ÷ 7`. Minimums: $10 CPA→$50-75/day, $25→$75-125, $50→$150-250, $100→$300-500. Can't afford 50 conv? Use $30-50/day for 5-7 days (directional, not statistically significant).

**Audience:** Broad (18-65+, target geography, no interest/behavior targeting, Advantage+ Audience ON). Results reflect scale; algorithm learns faster with more data.

**Placements:** Advantage+ Placements. Exception: placement hypothesis (e.g., Reels-only) → separate ad set.

**Ads/ad set:** 1-2 max. 1 ad: clearest learning. 2 (recommended): same angle, different formats (video + static). Avoid: mixing angles in same ad set, >3 ads, adding new ads to active ad sets.

## Testing Methodology

| Tier | What to Test | Impact |
|------|------|--------|
| 1 | Creative concept/angle (problem vs benefit, testimonial vs demo, UGC vs polished) | Highest |
| 2 | Hook (first 3s video, first line copy, opening visual) | High |
| 3 | Format (video vs static, carousel vs single, long vs short) | Medium |
| 4 | Copy elements (headlines, body length, CTA) | Medium |
| 5 | Visual elements (colors, fonts, minor design) | Lower |

**Variable isolation** — test one thing at a time:

```text
Bad:  Ad A: Video + Pain point + Long copy  /  Ad B: Static + Benefit + Short copy  → What won? Unknown.
Good: Ad A: Video + Pain point + Medium copy  /  Ad B: Video + Benefit + Medium copy → Benefit beats pain point.
```

**DCT (Dynamic Creative Testing):** Meta tests asset combinations automatically. Best for high volume (100+ conv/day) — but "black box." Manual: better for lower volume, clear learnings, concept testing.

**Sample size:** Statistical significance: 50+ conv/variation, 95% confidence, 7+ days. Directional: 20-30 conv/variation, 3-5 days. Calculator: ABTestGuide.com.

## Metrics & Decisions

| Objective | Primary Metrics |
|-----------|----------------|
| Purchases | CPA (at/below target), ROAS (at/above target), purchase volume |
| Leads | CPL (at/below target), lead quality (via CRM), lead volume |

**Diagnostic metrics:** CTR (compelling?), Hook Rate/3s (attention?), Hold Rate/15s (engaging?), ThruPlay Rate (full message?), CPM (competitive?), CPC (relevant?), Landing Page Views (clicks→visits?).

**Diagnostic flow:**

```text
Low Conversions?
1. High CPM (>$20)?       → Audience or quality issue
2. Low CTR (<0.8%)?       → Creative not compelling
3. Clicks ≠ LPV?          → Page load issues
4. Low CVR (<5%)?         → Landing page or offer issue
```

### Kill / Winner Decisions

| Timeframe | Kill if | Winner if |
|-----------|---------|-----------|
| Immediately | CTR <0.3% after 1K+ impressions; zero conv after 2× CPA spend; Quality Ranking bottom 20% | — |
| 3-5 days | CPA 50%+ above target (10+ conv); CTR <0.5% sustained | CPA at/below target, directional (20-50 conv) → proceed cautiously |
| 7 days | CPA 25%+ above target (30+ conv); declining trend | CPA at/below target 3+ days, 50+ conv, CTR >1%, stable → scale |
| 7+ days | — | 100+ conv at target → scale aggressively |

Don't react to Day 1 — wait 3 days consistent data. Inconsistent: check frequency (fatigue?) and external factors (weekend vs weekday).

## Testing Frameworks

**3-2-2 Method:** 3 ad sets (different angles) × 2 ads/ad set (same angle, different formats) × 2 weeks. Week 1: let all run. Week 2: kill losers. After 2 weeks: winners → scale.

**Rapid Fire:** 5+ ad sets, 1 ad each, $30-50/day, 3-5 day tests. Day 3: kill bottom 2. Day 5: kill 1-2 more. Winners → scale. Best for early stage, many ideas, smaller budgets.

**Concept testing** (big swings) → **Iteration testing** (optimize winner):

```text
Concept:   Ad Set 1: Testimonial UGC / Ad Set 2: Product demo / Ad Set 3: Founder talking head / Ad Set 4: Static comparison
Iteration: Ad Set 1: Testimonial - Hook A / Ad Set 2: Testimonial - Hook B / Ad Set 3: Testimonial - Hook C
```

### Hook Testing

First 3s (video) / first line (text) determine engagement.

| Category | Video Hook | Text Hook |
|----------|-----------|-----------|
| Curiosity | "Nobody talks about this..." | "The secret nobody talks about..." |
| Pain | "Tired of [problem]?" | "Still struggling with [problem]?" |
| Benefit | "[Result] in [timeframe]" | "How I got [result] in [timeframe]" |
| Controversy | "Unpopular opinion..." | "[Industry] is lying to you" |
| Story | "Last year I was [bad situation]..." | "I used to [struggle]..." |
| Social Proof | "How [Company] got [result]" | "[X] companies use this to..." |
| Question | "What if you could [desire]?" | "Ever wondered why [thing]?" |

Process: winning creative → 3-5 hook variations (same body) → test → winner hook + winner body = optimized ad. Then test body elements and CTAs (typically 5-20% lift).

## From Test to Scale

**Winner criteria:** CPA at/below target 3+ days, 50+ conversions, CTR >0.8% (ideally 1%+), stable/improving trend, frequency <3.

**Moving winners:** Duplicate whole ad set (preserves learning history) → scale campaign → Turn on. After graduating: keep testing new concepts, iterations, and different audiences.

**Testing velocity:** <$5K/mo: 2-3 concepts+iterations/week. $5-20K: 4-6. $20-50K: 6-10. $50K+: 10+. Rule: 20% of budget on testing new concepts.

## Launch Checklist

- [ ] Objective = Conversions; ABO enabled (not CBO)
- [ ] Budget/ad set calculated; same audience across ad sets
- [ ] Advantage+ Placements on; 1-2 ads/ad set; one variable per test
- [ ] Pixel/CAPI configured; UTM parameters added

| Day | Review Action |
|-----|--------|
| Daily | Check spend vs budget, early metrics (CTR, CPM), no disapprovals |
| Day 3 | Kill obvious losers; check technical issues |
| Day 7 | Kill underperformers; identify winners; plan next tests |
| Day 14 | Declare winners; move to scale; document learnings; plan iteration tests |

---

*Next: [Scaling Campaign (CBO)](scaling-cbo.md)*

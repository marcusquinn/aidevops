## Creative Testing & Optimization

### Core Principles

1. **Test ONE variable at a time** — isolate what's working; can't learn from multi-variable changes
2. **Volume matters** — need statistical significance; launch 5-10 creatives per test
3. **Speed wins** — weekly test launches, kill losers fast, scale winners immediately
4. **Data over opinions** — customer response decides, not personal preference

---

### Testing Framework (4 Levels)

#### Level 1: Concept Testing

Test different hooks/angles (problem vs. benefit, educational vs. promotional, emotional vs. logical).

- Same format, audience, budget per creative
- Minimum 3 days, ideally 7 days
- Success: CPA below target, scalable to $1K+/day, >14-day lifespan

```text
CONTROL: "Tired of [problem]?" hook
VARIANT 1: "How I [achieved result]" hook
VARIANT 2: "[Surprising statistic]" hook
VARIANT 3: "What if [hypothetical]?" hook
VARIANT 4: "Stop [bad behavior]" hook

Same cold audience | $50/day each | 7 days | Winner: Lowest CPA with >20 conversions
```

#### Level 2: Format Testing

Test image vs. video, short vs. long-form, UGC vs. professional, carousel vs. single — same messaging/angle across formats.

```text
CONCEPT: "Before/After Transformation"
FORMAT A: Single image split screen | FORMAT B: 15s time-lapse video
FORMAT C: 45s UGC testimonial | FORMAT D: Carousel (5 transformations)
FORMAT E: 60s professional showcase

Same headline/text/audience | $50/day each | 7 days
Metrics: CPA, CTR, hook rate (video), engagement rate
```

#### Level 3: Element Testing

Test one element at a time (headlines, primary text, CTAs, offers, thumbnails, video hooks). Keep everything else identical. Minimum 5 variations, run until 95% confidence with 50+ conversions per variant.

```text
Same video + same primary text, only headlines change:
1: "How to [Benefit] in [Timeframe]"  |  2: "[Number]+ [People] Trust [Product]"
3: "[Benefit] Without [Objection]"    |  4: "The Secret to [Outcome]"
5: "[Result] Guaranteed"

Same audience | Equal budget | 14 days | Winner: Lowest CPA + acceptable volume
```

#### Level 4: Audience-Message Match

Test same creative across different audiences, or tailored messaging per segment. Track CPA, LTV, and volume by segment. Run 14 days.

```text
PRODUCT: Project management software
Audience 1 (Agencies): "Manage 20+ client projects without chaos"
Audience 2 (In-house): "Get your team aligned on priorities"
Audience 3 (Solopreneurs): "Stop forgetting important tasks"

Budget weighted by audience size | Measure CPA and LTV by segment
```

---

### Variable Isolation

Change ONLY ONE at a time: creative type, creative content, audience, offer, or placement. Keep everything else constant.

```text
BAD:  New video + New headline + New audience + New offer → can't determine cause
GOOD: New video + Same headline + Same audience + Same offer → know it's the video
```

---

### Statistical Significance

**Why it matters:** Small samples = random noise. Can't make decisions on 10 conversions.

**Minimum conversion thresholds per variant:**

| Test type | Min conversions | Min confidence | Min duration |
|-----------|----------------|----------------|--------------|
| Image/text | 50+ | 95% | 7 days |
| Video | 30+ | 95% | 7 days |
| Audience | 100+ | 95% | 14 days |
| Format | 20+ | 95% | 7 days |

**Interpreting confidence levels:**
- **95%+**: Safe to declare winner and scale
- **90-94%**: Directional only — keep running until 95% if budget allows
- **<90%**: Insufficient evidence — do not declare winner

Use calculators: VWO, Optimizely Stats Engine, AB Test Guide, Google Analytics Experiments.

**Example:** Variant A: 100 conversions, 2.5% CVR, $40 CPA. Variant B: 110 conversions, 3.2% CVR, $31 CPA. Confidence: 96% → Scale Variant B.

---

### Creative Fatigue Detection

**Symptoms:** CTR declining week-over-week, CPA increasing, frequency >5, relevance score dropping, hook rate <35%.

| Metric | Fresh | Fatigued |
|--------|-------|----------|
| CTR decline | Stable/rising | >20% from peak |
| CPA increase | Stable/decreasing | >25% from baseline |
| Frequency | <3 | >5 |
| Relevance Score | Good/Excellent | Average/Below Average |
| Hook rate (video) | >50% | <35% |

**Refresh levels:**

| Level | Changes | Lifespan extension |
|-------|---------|-------------------|
| Minor refresh | Headline, thumbnail, offer, CTA | +7-14 days |
| Moderate update | New hook (first 3s), different image/video, rewrite text, update social proof | +14-30 days |
| New creative | Entirely new concept, angle, format, creators | 30-90 days |

**Prevention:** Rotate 5-10 creatives per ad set, launch new weekly, retire bottom 20% bi-weekly, use larger audiences, frequency cap max 4/7 days.

---

### Winner Identification & Scaling

**Phase 1 — Initial assessment (days 1-3):** Eliminate non-starters (0 conversions at $200+ spend). Identify early leaders. Don't make final decisions.

**Phase 2 — Data accumulation (days 4-7):** Let remaining creatives accumulate data. Monitor for statistical significance and secondary metrics.

**Phase 3 — Winner declaration (day 7+):**

A creative is a winner if: CPA 20%+ better than target, volume >10 conversions/day potential, confidence >=95%, stable (not declining).

**Decision verdicts:**

| Verdict | Criteria | Action |
|---------|----------|--------|
| SCALE | CPA well below target, good volume, stable trend | Increase budget |
| KEEP MONITORING | Near target CPA, moderate volume, mixed trend | Continue testing |
| OPTIMIZE | High engagement but CPA above target | Adjust elements |
| EXPAND AUDIENCE | Great efficiency but low volume | Broaden targeting |
| KILL | CPA well above target, low engagement, declining | Pause immediately |

**Scaling approach:**

```text
Gradual: $50-100/day → 2x at day 8 → 2x at day 15 → 20-40% increases thereafter
Rapid (clear winners, CPA 30%+ below target): 5x at day 8, monitor closely
```

**Phase 4 — Iterate on winners:** Create variations (different creator same script, same creator different hook, shorter version, different product focus, different editing style). Build a "creative cluster" around winning concepts.

---

### Testing Calendar

| Week | Monday | Wednesday | Friday |
|------|--------|-----------|--------|
| 1 | Launch 5 concept tests | Kill non-starters | Analyze mid-week |
| 2 | Scale W1 winners + 5 element tests | Refresh fatigued creatives | Weekly review |
| 3 | Format tests on winning concepts | Audience expansion tests | Monthly review |
| 4 | Variations of top performers | Kill bottom 25% | Plan next month |

**Monthly:** Creative audit, performance ranking, fatigue analysis, testing insights documentation, new angle brainstorming.

---

### Testing Frameworks

**Sequential:** Test headlines (week 1) → winning headline + test images (week 2) → winning combo + test CTAs (week 3) → + test offers (week 4). Build optimized creative layer by layer.

**Champion vs. Challengers:** 1 champion (40% budget) + 4-5 challengers (15% each). Weekly: best challenger beats champion? Swap. Worst challenger replaced. Always have a safe bet + continuous testing.

**Bracket:** 8 variations (equal budget) → top 4 get more → top 2 battle → winner gets full budget. Fast elimination, efficient allocation.

---

### A/B Testing Methodology

**A/B test** = one variable, two+ variations, clear learnings.
**Multivariate test** = multiple variables, many combinations, requires more traffic.

**Priority testing order:**

| Tier | Elements | Impact |
|------|----------|--------|
| 1 (Highest) | Hook (first 3s), value proposition, offer, creative format | Largest CPA/ROAS impact |
| 2 (High) | Headline, visual, CTA, social proof | Significant CTR/CVR impact |
| 3 (Medium) | Primary text, description, button color/text, length | Moderate impact |
| 4 (Lower) | Emoji usage, capitalization, pricing display, urgency language | Incremental |

**Methodology steps:**

1. **Hypothesis:** "If we change [variable] from [A] to [B], [metric] will [improve] because [reasoning]."
2. **Design:** Control vs. variant(s), everything else identical. Winner becomes new control.
3. **Traffic:** Equal split (50/50) default. Unequal (80/20) when protecting a strong control.
4. **Duration:** Per-test-type thresholds from **Statistical Significance** table; >=95% confidence before winner declaration; minimum 7 days (day-of-week variance).
5. **Analysis:** Primary metric (CPA/ROAS), then secondary (CTR, CVR, CPC, watch time, engagement).
6. **Implementation:** Scale winner (new control), pause loser (document why), plan next test.

**Example — Headline test:**

```text
Hypothesis: Specific benefit headlines outperform question headlines
Control: "Want Better Project Management?"
B: "Manage Projects 50% Faster" | C: "Never Miss a Deadline Again" | D: "The PM Tool Your Team Will Actually Use"
Same image/copy/audience | $equal budget | 7 days | 100+ conversions each

Results: A: $48 CPA, 1.2% CTR | B: $52 CPA, 0.9% CTR (loser) | C: $39 CPA, 1.8% CTR (WINNER) | D: $44 CPA, 1.4% CTR
Learning: Specific benefit > generic benefit > question; C won on both CPA and CTR
Action: C becomes control, test more specific benefit angles
```

**Example — Offer test:**

```text
Hypothesis: Free trial outperforms discount
Control: "40% off first month"
B: "Free 30 days, no credit card" | C: "First month free, then $29/mo" | D: "50% off for 3 months"
Same creative/headline/audience | 14 days | 120+ conversions each

Results: A: $44 CPA, $180 LTV, 3.1% CVR | B: $36 CPA, $245 LTV, 4.2% CVR (WINNER) | C: $38 CPA, $220 LTV, 3.8% CVR | D: $42 CPA, $165 LTV, 2.9% CVR
Learning: Free trial best CPA AND best LTV; no-CC reduced friction; B's higher CVR drove lower CPA
```

---

### Common Testing Mistakes

| Mistake | Problem | Fix |
|---------|---------|-----|
| Multiple variables | Can't determine cause | One variable at a time |
| Stopping too early | Random noise, not real results | Wait for significance + min sample + min duration |
| Too short duration | Misses day-of-week variance | Minimum 7 days |
| Unequal samples | Unfair comparison | Equal traffic split |
| Wrong metric | High CTR but worse CPA | Optimize for primary business metric (CPA/ROAS) |
| No documentation | Repeat failed tests | Maintain test log with learnings |

---

### Test Documentation Template

```text
TEST ID: [Unique ID] | DATE: [Start-End] | CAMPAIGN: [Name]
HYPOTHESIS: [What and why]
CONTROL: [Description] | VARIANT(S): [Description each]
VARIABLE: [Headline/Image/Hook/Offer/etc.]
AUDIENCE: [Who] | BUDGET: [$/variant] | DURATION: [Days]
RESULTS: [CPA, CTR, Conversions, Confidence per variant]
WINNER: [Which and why] | CONFIDENCE: [%]
LEARNINGS: [Key insight] | NEXT STEPS: [What to test next]
```

**Build institutional knowledge:** Winners library (what won and why), losers library (what failed and lessons), best practices log (accumulated patterns like "numbers in headlines outperform generic").

---

## Ad Creative Scoring Rubrics

### Pre-Launch Creative Scorecard (100 points)

| Category | Points | Criteria (5 pts each) |
|----------|--------|----------------------|
| **Hook Quality** | /25 | Pattern interrupt, relevance signal, curiosity/desire, clarity, specificity |
| **Value Proposition** | /20 | Benefit clarity, differentiation, proof, relevance to target |
| **Creative Execution** | /20 | Production quality, native feel, mobile optimization, branding |
| **Copy Quality** | /20 | Headline, primary text, CTA, tone/voice |
| **Offer & CTA** | /15 | Offer strength, urgency/scarcity, friction reduction |

**Scoring scale per criterion:** 5 = excellent, 3 = adequate, 1 = weak/missing.

**Score interpretation:**

| Score | Rating | Action |
|-------|--------|--------|
| 90-100 | Excellent | Launch with high confidence |
| 75-89 | Good | Launch with minor tweaks |
| 60-74 | Average | Needs improvement before launch |
| <60 | Weak | Major revision needed |

**Example scoring:**

```text
UGC video for sleep supplement — 89/100 (GOOD)
Hook Quality: 22/25 (strong sleep struggle visual, clear audience, good curiosity, slightly unclear product name, needs specific stat)
Value Prop: 18/20 (clear benefit, personal testimonial, natural ingredients but no unique mechanism)
Execution: 18/20 (authentic UGC, platform-native, vertical+captions, product could be clearer)
Copy: 17/20 (strong headline "Fall Asleep in Under 20 Minutes", clear CTA "Try free 30 days", tone could match testimonial energy more)
Offer: 14/15 (30-day free trial, no CC required, could add urgency)
Recommendation: Launch; test variation with specific stat in hook + urgency in offer
```

### Post-Launch Performance Scorecard (100 points, after 7 days)

| Metric | Points | Scoring |
|--------|--------|---------|
| CPA vs. target | /30 | 30%+ better=30, 10-29%=25, 0-9%=20, 0-10% worse=15, 10-25% worse=10, 25%+ worse=0 |
| Volume | /20 | >20 conv/day=20, 10-19=15, 5-9=10, 1-4=5, <1=0 |
| CTR | /15 | >3%=15, 2-3%=12, 1-2%=8, 0.5-1%=4, <0.5%=0 |
| Hook rate (video) | /15 | >60%=15, 50-60%=12, 40-49%=8, 30-39%=4, <30%=0 |
| Engagement | /10 | Above avg=10, at avg=7, below=4, far below=0 |
| Longevity | /10 | Improving=10, stable=8, slight decline=5, significant decline=0 |

**Actions:** 85-100: Scale aggressively | 70-84: Scale moderately | 50-69: Keep testing | 30-49: Optimize or pause | <30: Kill

### Video-Specific Scoring (100 points)

| Element | Points | Criteria |
|---------|--------|----------|
| Hook (first 3s) | /30 | Visual scroll-stop (10), verbal/text hook (10), immediate relevance (10) |
| Pacing | /15 | Cut frequency (5), energy level (5), maintains interest (5) |
| Storytelling | /15 | Clear narrative arc (5), emotional connection (5), satisfying resolution (5) |
| Audio | /10 | Sound quality (5), music choice (3), voice clarity (2) |
| Captions | /10 | Readable/visible (5), synced (3), styled appropriately (2) |
| CTA | /10 | Verbally stated (3), visually shown (3), clear next step (4) |
| Branding | /5 | Product/brand clear (5), somewhat clear (3), unclear (0) |
| Technical | /5 | Proper aspect ratio (2), good lighting (2), stable footage (1) |

### Image Ad Scoring (100 points)

| Element | Points | Criteria |
|---------|--------|----------|
| Visual impact | /25 | Thumb-stopping (10), clear focal point (8), color contrast (7) |
| Composition | /20 | Rule of thirds/balance (7), hierarchy (7), not cluttered (6) |
| Text overlay | /15 | Minimal text (5), high contrast/readable (5), complements headline (5) |
| Product showcase | /15 | Product visible/clear (10), in context/lifestyle (5) |
| Branding | /10 | Logo visible not overwhelming (5), brand colors (3), consistency (2) |
| Mobile readiness | /10 | Works at small sizes (5), important elements centered (3), no tiny text (2) |
| Platform fit | /5 | Looks native (5), somewhat native (3), out of place (0) |

### Scoring Process

**Pre-launch:** Score before launch. Only launch 75+. Iterate on 60-74. Scrap below 60.

**Post-launch:** Score after 7 days. Compare pre-launch score to actual performance. Build pattern recognition ("ads scoring 85+ pre-launch typically achieve CPA 20% below target"). Adjust rubric based on learnings.

---

## Dynamic Creative Optimization (DCO)

DCO uses machine learning to test creative combinations automatically and serve the best-performing version to each user.

**Platforms:** Meta (Dynamic Creative), Google (RSA, RDA, Performance Max), TikTok (Smart Creative), Snapchat (Dynamic Ads), LinkedIn (Dynamic Ads).

### Meta Dynamic Creative

Provide up to 10 images/videos, 5 headlines, 5 primary text options, 5 descriptions. Meta tests all combinations, learns optimal pairings, serves best to each viewer.

**Setup:** Enable Dynamic Creative at ad level → upload assets → let run 7+ days (50-100 conversions for learning) → review asset performance report.

**Asset strategy:**

```text
IMAGES/VIDEOS (10): 3 product-focused, 3 lifestyle/in-use, 2 before-after/testimonial, 2 promotional
PRIMARY TEXT (5): 2 benefit hooks, 1 problem hook, 1 question hook, 1 social proof hook
HEADLINES (5): 2 benefit-driven, 1 offer-focused, 1 social proof, 1 urgency-based
DESCRIPTIONS (5): Offer details, guarantee/risk reversal, social proof, urgency, feature highlight
```

**Analysis:** After 7+ days, check asset performance report. Scale high performers (more variations). Replace low performers. Document learnings.

**When to use DCO:**
- Yes: Quick concept testing, scaling creative production, broad audiences, limited creative bandwidth
- No: Precise message control needed, very specific audience segments, isolated variable testing, brand-sensitive content

### Google Responsive Search Ads

Provide 15 headlines + 4 descriptions. Google tests combinations. Review asset performance weekly. Replace "Low" performing assets. Iterate on 4-week cycles.

### Google Performance Max

**Asset group:** 20 images (all 3 aspect ratios), 5 videos (multiple ratios), 5 headlines, 5 long headlines, 5 descriptions, 5 logos. Google optimizes across Search, Display, YouTube, Discover, Gmail, Maps.

**Best practices:**
1. Provide maximum assets (20 images, 5 videos, all text slots filled)
2. Provide audience signals (custom audiences, interests, demographics — used as hints, not restrictions)
3. Separate asset groups by product category/audience segment
4. Check asset performance report weekly; replace poor performers, create more like top performers

**Example asset group:**

```text
PRODUCT: Running shoes
IMAGES (20): 8 landscape (3 product-only, 3 person running, 2 close-up), 8 square (3 product, 3 lifestyle, 2 before/after), 4 portrait (2 product, 2 full body)
VIDEOS (5): 1 horizontal showcase, 2 vertical demos, 1 square testimonial, 1 horizontal "how it's made"
SHORT HEADLINES: "Premium Running Shoes" | "Run Faster, Recover Quicker" | "Free Shipping + Returns" | "4.8-star Rated by Runners" | "Shop Best Sellers"
LONG HEADLINES: Performance + comfort | Award-winning cushioning | Free shipping + 60-day returns | Trusted by 50K+ runners | Top-rated, all sizes in stock
DESCRIPTIONS: Cushioning tech + lightweight | 50K+ runners, 4.8 stars, free shipping | Limited time free shipping, 60-day trial | Responsive foam, breathable mesh, 500+ miles | Free shipping + runner community access
```

### TikTok Smart Creative

Provide multiple video clips, text options, CTAs. TikTok assembles, tests combinations, uses trending audio. Content must be vertical (9:16), fast-paced, creator-style (not brand-style).

### DCO vs. Manual Testing

| | DCO | Manual A/B |
|---|-----|-----------|
| **Strengths** | Faster, tests at scale, continuous optimization, cross-placement, resource efficient | Complete control, isolate variables, precise audience-message match, brand-safe |
| **Weaknesses** | Less control, can't isolate variables, platform-dependent, less granular reporting | Time-intensive, slower learning, more creative production, can't test all combos |

**Recommended hybrid approach:**
1. **DCO for concept discovery** — find winning concepts quickly at broad scale
2. **Manual testing for refinement** — take DCO winners, run focused A/B tests, refine messaging
3. **DCO for scaling** — create asset variations of manual test winners, scale with DCO

### DCO Optimization Checklist

- Maximum assets provided (don't leave slots empty)
- Assets are diverse (not minor variations)
- Each asset stands alone (no dependencies between assets)
- Headlines work in any combination with descriptions
- Images/videos match all possible text combinations
- Asset quality is high (no filler)
- Sufficient budget for learning ($50-100+/day)
- Ran minimum 7 days
- Checked asset performance report
- Replaced low performers, created more variations of high performers
- Documented learnings

---

## Creative Performance Metrics

### Primary Metrics

**CPA (Cost Per Acquisition):** Total Spend / Conversions. Lower = better creative efficiency. Compare across creatives to find winners. Track trend over time.

**ROAS (Return On Ad Spend):** Revenue / Ad Spend. Target typically 3-5x for e-commerce. Balance with scale (lower ROAS sometimes acceptable for more volume). Break-even ROAS = 1 / Profit Margin.

**CTR (Click-Through Rate):** (Clicks / Impressions) x 100. Indicates thumb-stop power. Watch for high CTR + low CVR (bad targeting or misleading ad).

| Platform | Good CTR | Great CTR |
|----------|----------|-----------|
| Facebook Feed | 1.5-2% | 3%+ |
| Facebook Stories | 0.8-1.2% | 2%+ |
| Instagram Feed | 1-1.5% | 2.5%+ |
| Instagram Stories | 0.5-1% | 1.5%+ |
| Google Search | 3-5% | 8%+ |
| Google Display | 0.3-0.5% | 1%+ |
| YouTube | 0.5-1% | 2%+ |
| TikTok | 1-2% | 3%+ |

**CVR (Conversion Rate):** (Conversions / Clicks) x 100. Benchmarks: e-commerce 2-5%, lead gen 5-15%, SaaS trials 3-10%. Low CVR = landing page or offer problem. High CVR + high CPA = traffic too expensive (improve CTR). Key relationship: CPA = CPC / CVR.

### Video-Specific Metrics

**Hook Rate (3-Second View Rate):** % who watch past first 3 seconds. Good: 50%+, great: 60%+, excellent: 70%+. Low = weak hook. Highest leverage optimization point.

**Hold Rate (Average Watch Time):** Total Watch Time / Total Views. Benchmarks: 30-40% for feed, 50-70% for Stories/Reels. Low = lost interest (pacing/content). Aim 25%+ completion minimum.

**ThruPlay (Facebook):** Video watched to completion or 15+ seconds. Cost per ThruPlay target: <$0.05-0.10. ThruPlay rate target: >25%.

**Video view definitions vary by platform:**
- Facebook/Instagram: 3s view, 10s view, ThruPlay (end or 15s)
- YouTube: 30+ seconds or interaction
- TikTok: Any watch time (1s+); full view = 100% completion

### Engagement Metrics

**Engagement Rate:** Total engagements (likes, comments, shares, saves, clicks) / Impressions. Average: 1-3%, good: 3-6%, excellent: 6%+.

**Comment Sentiment:** Read comments for creative fatigue signals ("sick of seeing this"), objections to address, and messaging opportunities.

**Save Rate (Instagram):** High-intent action (want to reference later). Strong value signal, boosts organic reach.

**Share Rate:** Highest-intent engagement. Extends reach organically. Driven by relatable, funny, educational, or emotional content.

### Cost Metrics

**CPM (Cost Per 1,000 Impressions):** (Spend / Impressions) x 1,000. Indicates auction competitiveness and creative quality (better creative = lower CPM). Benchmarks: Facebook $5-15, Instagram $5-10, LinkedIn $30-100, Google Display $2-10.

**CPC (Cost Per Click):** Spend / Clicks. Measures traffic acquisition efficiency.

**CPL (Cost Per Lead):** Same as CPA for lead-gen. Benchmarks: B2C $5-20, B2B $50-200+.

### Quality Metrics (Facebook)

Facebook rates ads on three rankings (replaced the old 1-10 relevance score):

| Ranking | Measures | Low score means |
|---------|----------|-----------------|
| Quality Ranking | Ad quality vs. competitors for same audience | Creative isn't resonating — improve visuals/messaging |
| Engagement Rate Ranking | Expected engagement vs. competitors | Ad is boring — improve thumb-stop power, hook |
| Conversion Rate Ranking | Expected CVR vs. competitors | Misleading ad or bad landing page — ensure message match |

Higher rankings = lower costs + better delivery. Improve via better creative, targeting, offer, and reducing negative feedback.

### Attribution

**View-through conversions:** Saw ad, didn't click, converted later. Measures awareness impact. Especially relevant for video ads.

**Click-through conversions:** Clicked ad, then converted. More reliable direct attribution.

**Attribution windows:**

| Platform | Default | Other Options |
|----------|---------|---------------|
| Facebook | 7-day click or 1-day view | 1-day click or 1-day view, 28-day options |
| Google | Data-driven (recommended) | Last click, first click, linear, time decay, position-based |

Different windows = different CPA reporting.

### Monitoring Cadence

**Daily (quick check):** Spend on track, CPA/ROAS hitting targets, sufficient volume, any major CTR drops.

**Weekly (deep dive):** Creative winners/losers, frequency/fatigue, audience performance, trends, quality rankings.

**Monthly (strategic):** Overall account health, creative library performance, winning/losing patterns, competitive benchmarks, YoY/MoM trends.

### Metrics by Campaign Objective

| Objective | Primary metrics | Secondary metrics |
|-----------|----------------|-------------------|
| Awareness | CPM, reach, video views, ThruPlay | Engagement, share rate |
| Consideration | CTR, CPC, video views | Engagement, landing page views |
| Conversion | CPA, ROAS, CVR | CTR, CPC |

### ROI Calculation

```text
ROI = (Revenue - Ad Spend) / Ad Spend x 100
Example: ($25,000 - $5,000) / $5,000 x 100 = 400%

Break-even ROAS = 1 / Profit Margin
Example: 1 / 0.40 = 2.5 (need 2.5:1 ROAS to break even)
```

### Tools

**Native:** Facebook Ads Manager, Google Ads, TikTok Ads Manager

**Attribution/tracking:** Google Analytics (website behavior), Triple Whale (e-commerce/Shopify), Hyros (advanced attribution), Northbeam (attribution platform)

**Reporting:** Google Data Studio (free dashboards), Supermetrics (automated), Funnel.io (multi-platform aggregation)

**Creative intelligence:** Foreplay.co (ad library inspiration), Madgicx (creative insights), Motion.io (creative management), Smartly.io (campaign automation)

**A/B test calculators:** VWO, Optimizely Stats Engine, AB Test Guide, Google Analytics Experiments

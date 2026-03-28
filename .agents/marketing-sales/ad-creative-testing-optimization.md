## Creative Testing & Optimization

### Core Principles

1. **One variable at a time** — isolate cause; multi-variable changes are unlearnable
2. **Volume** — 5-10 creatives per test; statistical significance required
3. **Speed** — weekly launches, kill losers fast, scale winners immediately
4. **Data over opinions** — customer response decides

---

### Testing Framework

| Level | What to test | Setup | Duration |
|-------|-------------|-------|----------|
| 1 — Concept | Hook/angle (problem vs. benefit, emotional vs. logical) | Same format/audience/budget | 7 days |
| 2 — Format | Image vs. video, UGC vs. professional, carousel vs. single | Same messaging across formats | 7 days |
| 3 — Element | One element: headline, CTA, offer, thumbnail, hook | 5+ variations, everything else identical | Until 95% confidence + 50 conv/variant |
| 4 — Audience-Message | Same creative across segments, or tailored messaging per segment | Budget weighted by audience size | 14 days |

**Statistical significance:**

| Test type | Min conversions | Min confidence | Min duration |
|-----------|----------------|----------------|--------------|
| Image/text | 50+ | 95% | 7 days |
| Video | 30+ | 95% | 7 days |
| Audience | 100+ | 95% | 14 days |
| Format | 20+ | 95% | 7 days |

**95%+**: Declare winner, scale. **90-94%**: Directional only — keep running if budget allows. **<90%**: Insufficient — do not declare winner. Calculators: VWO, Optimizely Stats Engine, AB Test Guide.

**Testing approaches:**

- **Sequential:** Headlines (wk 1) → winning headline + images (wk 2) → winning combo + CTAs (wk 3) → + offers (wk 4).
- **Champion vs. Challengers:** 1 champion (40% budget) + 4-5 challengers (15% each). Weekly: best challenger beats champion → swap; worst replaced.
- **Bracket:** 8 variations equal budget → top 4 get more → top 2 battle → winner gets full budget.

**Element priority order:**

| Tier | Elements | Impact |
|------|----------|--------|
| 1 (Highest) | Hook (first 3s), value proposition, offer, creative format | Largest CPA/ROAS impact |
| 2 (High) | Headline, visual, CTA, social proof | Significant CTR/CVR impact |
| 3 (Medium) | Primary text, description, button color/text, length | Moderate |
| 4 (Lower) | Emoji, capitalization, pricing display, urgency language | Incremental |

**Process:** Hypothesis → control vs. variant (all else identical) → equal split (80/20 when protecting strong control) → run per significance thresholds → analyze CPA/ROAS then CTR/CVR/watch time → scale winner, pause loser, document, plan next.

**Common mistakes:** Multiple variables (test one) | Stopping too early (wait for significance + min sample + min duration) | Duration <7 days (day-of-week variance) | Unequal samples | Optimizing CTR instead of CPA/ROAS | No documentation.

**Test log fields:** ID | Date | Campaign | Hypothesis | Control | Variant(s) | Variable | Audience | Budget/variant | Duration | Results (CPA, CTR, conv, confidence) | Winner | Learnings | Next steps. Build: winners library, losers library, best practices log.

---

### Creative Fatigue

| Metric | Fresh | Fatigued | Refresh |
|--------|-------|----------|---------|
| CTR | Stable/rising | >20% drop from peak | Minor: headline, thumbnail, offer, CTA (+7-14 days) |
| CPA | Stable/decreasing | >25% above baseline | Moderate: new hook/image/video, rewrite text, update social proof (+14-30 days) |
| Frequency | <3 | >5 | New creative: new concept, angle, format, creators (30-90 days) |
| Hook rate (video) | >50% | <35% | |

**Prevention:** Rotate 5-10 creatives/ad set, launch new weekly, retire bottom 20% bi-weekly, frequency cap max 4/7 days.

---

### Winner Identification & Scaling

**Timeline:** Days 1-3: eliminate non-starters (0 conv at $200+ spend). Days 4-7: accumulate data. Day 7+: declare winner if CPA 20%+ better than target, >10 conv/day potential, 95%+ confidence, stable trend.

| Verdict | Criteria | Action |
|---------|----------|--------|
| SCALE | CPA well below target, good volume, stable | Increase budget |
| KEEP MONITORING | Near target CPA, moderate volume, mixed trend | Continue |
| OPTIMIZE | High engagement but CPA above target | Adjust elements |
| EXPAND AUDIENCE | Great efficiency, low volume | Broaden targeting |
| KILL | CPA well above target, low engagement, declining | Pause immediately |

**Scaling:** Gradual: $50-100/day start, increase 15-20% every 3-4 days while KPIs hold. Rapid (CPA 30%+ below target): cap increases at 20% to avoid re-entering learning phase; use spend caps, rollback triggers, daily CPA/ROAS checks.

**Iterate on winners:** Different creator/same script, same creator/different hook, shorter cut, different product focus. Build a "creative cluster" around winning concepts.

---

### Testing Calendar

| Week | Monday | Wednesday | Friday |
|------|--------|-----------|--------|
| 1 | Launch 5 concept tests | Kill non-starters | Analyze mid-week |
| 2 | Scale W1 winners + 5 element tests | Refresh fatigued creatives | Weekly review |
| 3 | Format tests on winning concepts | Audience expansion tests | Monthly review |
| 4 | Variations of top performers | Kill bottom 25% | Plan next month |

Monthly: creative audit, performance ranking, fatigue analysis, testing insights, new angle brainstorming.

---

## Ad Creative Scoring Rubrics

### Pre-Launch Scorecard (100 pts)

| Category | Points | Criteria (5 pts each) |
|----------|--------|----------------------|
| Hook Quality | /25 | Pattern interrupt, relevance signal, curiosity/desire, clarity, specificity |
| Value Proposition | /20 | Benefit clarity, differentiation, proof, relevance to target |
| Creative Execution | /20 | Production quality, native feel, mobile optimization, branding |
| Copy Quality | /20 | Headline, primary text, CTA, tone/voice |
| Offer & CTA | /15 | Offer strength, urgency/scarcity, friction reduction |

Scoring: 5 = excellent, 3 = adequate, 1 = weak/missing. Launch 75+, iterate 60-74, scrap <60. Compare pre-launch score to actual performance after 7 days for pattern recognition.

### Post-Launch Scorecard (100 pts, after 7 days)

| Metric | Points | Scoring |
|--------|--------|---------|
| CPA vs. target | /30 | 30%+ better=30, 10-29%=25, 0-9%=20, 0-10% worse=15, 10-25% worse=10, 25%+ worse=0 |
| Volume | /20 | >20 conv/day=20, 10-19=15, 5-9=10, 1-4=5, <1=0 |
| CTR | /15 | >3%=15, 2-3%=12, 1-2%=8, 0.5-1%=4, <0.5%=0 |
| Hook rate (video) | /15 | >60%=15, 50-60%=12, 40-49%=8, 30-39%=4, <30%=0 |
| Engagement | /10 | Above avg=10, at avg=7, below=4, far below=0 |
| Longevity | /10 | Improving=10, stable=8, slight decline=5, significant decline=0 |

Actions: 85-100 scale aggressively | 70-84 scale moderately | 50-69 keep testing | 30-49 optimize or pause | <30 kill.

### Video Scorecard (100 pts)

Hook (first 3s) /30: visual scroll-stop (10), verbal/text hook (10), immediate relevance (10). Pacing /15: cut frequency (5), energy level (5), maintains interest (5). Storytelling /15: clear narrative arc (5), emotional connection (5), satisfying resolution (5). Audio /10: sound quality (5), music choice (3), voice clarity (2). Captions /10: readable/visible (5), synced (3), styled (2). CTA /10: verbally stated (3), visually shown (3), clear next step (4). Branding /5: product/brand clear (5), somewhat clear (3), unclear (0). Technical /5: proper aspect ratio (2), good lighting (2), stable footage (1).

### Image Ad Scorecard (100 pts)

Visual impact /25: thumb-stopping (10), clear focal point (8), color contrast (7). Composition /20: rule of thirds/balance (7), hierarchy (7), not cluttered (6). Text overlay /15: minimal text (5), high contrast/readable (5), complements headline (5). Product showcase /15: product visible/clear (10), in context/lifestyle (5). Branding /10: logo visible not overwhelming (5), brand colors (3), consistency (2). Mobile readiness /10: works at small sizes (5), important elements centered (3), no tiny text (2). Platform fit /5: looks native (5), somewhat native (3), out of place (0).

---

## Dynamic Creative Optimization (DCO)

DCO uses ML to test creative combinations automatically and serve the best-performing version per user. **Platforms:** Meta (Dynamic Creative), Google (RSA, RDA, Performance Max), TikTok (Smart Creative), Snapchat (Dynamic Ads), LinkedIn (Dynamic Ads).

### Meta Dynamic Creative

Up to 10 images/videos, 5 headlines, 5 primary texts, 5 descriptions. Meta tests all combinations, learns optimal pairings. Enable at ad level → upload assets → run 7+ days (50-100 conversions for learning) → review asset performance report.

**Asset mix:** Images/videos (10): 3 product-focused, 3 lifestyle/in-use, 2 before-after/testimonial, 2 promotional. Primary text (5): 2 benefit hooks, 1 problem hook, 1 question hook, 1 social proof hook. Headlines (5): 2 benefit-driven, 1 offer-focused, 1 social proof, 1 urgency-based. Descriptions (5): offer details, guarantee/risk reversal, social proof, urgency, feature highlight.

**Use DCO when:** quick concept testing, broad audiences, limited bandwidth. **Avoid when:** precise message control, isolated variable testing, brand-sensitive content.

### Google RSA / Performance Max

**RSA:** 15 headlines + 4 descriptions. Review asset performance weekly. Replace "Low" assets. Iterate on 4-week cycles. **Performance Max:** 20 images (all 3 aspect ratios), 5 videos, 5 headlines, 5 long headlines, 5 descriptions, 5 logos. Provide audience signals (hints, not restrictions). Separate asset groups by product/segment. Replace poor performers weekly.

### TikTok Smart Creative

Multiple video clips, text options, CTAs. TikTok assembles and tests combinations with trending audio. Content must be vertical (9:16), fast-paced, creator-style.

### DCO vs. Manual Testing

| | DCO | Manual A/B |
|---|-----|-----------|
| Strengths | Faster, tests at scale, continuous optimization, resource efficient | Complete control, isolate variables, precise audience-message match, brand-safe |
| Weaknesses | Less control, can't isolate variables, less granular reporting | Time-intensive, slower learning, more production required |

**Hybrid:** DCO for concept discovery → manual A/B to refine → DCO to scale.

---

## Creative Performance Metrics

### Primary Metrics

| Metric | Formula | Notes |
|--------|---------|-------|
| CPA | Spend / Conversions | Lower = better. Track trend. |
| ROAS | Revenue / Ad Spend | Target 3-5x e-commerce. Break-even = 1 / Profit Margin. |
| CTR | (Clicks / Impressions) x 100 | High CTR + low CVR = bad targeting or misleading ad. |
| CVR | (Conversions / Clicks) x 100 | Benchmarks: e-commerce 2-5%, lead gen 5-15%, SaaS trials 3-10%. |

**CTR benchmarks:** Facebook Feed 1.5-2% (great 3%+) | Facebook Stories 0.8-1.2% (2%+) | Instagram Feed 1-1.5% (2.5%+) | Instagram Stories 0.5-1% (1.5%+) | Google Search 3-5% (8%+) | Google Display 0.3-0.5% (1%+) | YouTube 0.5-1% (2%+) | TikTok 1-2% (3%+).

### Video Metrics

| Metric | Good | Great | Excellent |
|--------|------|-------|-----------|
| Hook Rate (3s view) | 50%+ | 60%+ | 70%+ |
| Hold Rate (avg watch) | 30-40% feed | 50-70% Stories/Reels | -- |
| ThruPlay rate | >25% | -- | -- |
| Cost per ThruPlay | <$0.10 | <$0.05 | -- |

View definitions: Facebook/Instagram = 3s, 10s, ThruPlay (end or 15s). YouTube = 30s or interaction. TikTok = any watch (1s+); full view = 100% completion.

### Engagement, Cost & Quality

**Engagement Rate:** Total engagements / Impressions. Average 1-3%, good 3-6%, excellent 6%+. Read comments for fatigue signals and objections. **CPM:** Facebook $5-15, Instagram $5-10, LinkedIn $30-100, Google Display $2-10. **CPL:** B2C $5-20, B2B $50-200+.

**Facebook Quality Rankings:** Quality Ranking (ad quality vs. competitors — fix visuals/messaging) | Engagement Rate Ranking (expected engagement — improve thumb-stop power, hook) | Conversion Rate Ranking (expected CVR — fix message match or landing page). Higher rankings = lower costs + better delivery.

**Attribution:** Meta default = 7-day click + 1-day view. Google default = data-driven. Windows/models vary by platform, objective, and account — verify current settings before interpreting CPA/ROAS.

**Monitoring cadence:** Daily: spend, CPA/ROAS, volume, CTR drops. Weekly: winners/losers, fatigue, audience, quality rankings. Monthly: account health, creative library, patterns, competitive benchmarks. **Metrics by objective:** Awareness → CPM, reach, video views, ThruPlay. Consideration → CTR, CPC, video views. Conversion → CPA, ROAS, CVR.

**ROI:** `(Revenue - Spend) / Spend x 100`. Break-even ROAS = `1 / Profit Margin` (e.g., 40% margin = 2.5x).

**Tools:** Native: Facebook Ads Manager, Google Ads, TikTok Ads Manager. Attribution: Google Analytics, Triple Whale, Hyros, Northbeam. Reporting: Looker Studio, Supermetrics, Funnel.io. Creative intelligence: Foreplay.co, Madgicx, Motion.io, Smartly.io. A/B calculators: VWO, Optimizely Stats Engine, AB Test Guide.

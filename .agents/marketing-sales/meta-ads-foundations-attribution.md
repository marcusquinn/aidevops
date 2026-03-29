# Attribution & Measurement

> What Meta reports and what actually happened can be very different. Understanding attribution is critical for making good decisions.

## Attribution Windows

| Window | Best For |
|--------|----------|
| 1-day click | Conservative / impulse purchases |
| 7-day click | Standard ecommerce (2026 default) |
| 7-day click, 1-day view | Most campaigns — 1-7 day consideration |
| 28-day click (API only) | B2B / enterprise / long sales cycles |
| 1-day view | Brand awareness |

**Set in Ads Manager:** Campaign → Edit → Attribution setting. Changing the window affects reporting only — not delivery.

## Click-Through vs View-Through

**Click-through:** User clicked your ad then converted. Clear intent, direct path.

**View-through:** User saw your ad (no click), then converted later. Captures brand awareness but can feel inflated. Post-iOS 14, ~80%+ of iOS users opt out — view-through increasingly represents Android/web only; iOS conversion data is modeled, not directly tracked.

**Multi-touch reality:** Ad view → ad view → external research → brand search → direct conversion. Attribution can't confirm causality.

## What Meta Reports vs Reality

Meta's attribution is designed to show Meta ads in the best light.

- **Over-reports:** Multiple platforms claim the same conversion; view-through may not be causal; post-iOS modeling can over-estimate.
- **Under-reports:** iOS users, ad blocker users, cross-device journeys, long purchase cycles exceeding the window.

| What Meta Reports | What Likely Happened |
|-------------------|---------------------|
| 100 purchases | 70-90 actually from Meta |
| $50 CPA | $55-75 true CPA |
| 3x ROAS | 2-2.5x true ROAS |

**Rule of thumb:** Discount Meta-reported conversions by 10-30%.

## Incrementality Testing

The gold standard for measuring true ad impact.

```
Incrementality = (Test Group Conversions - Control Group Conversions) / Test Group Conversions
```

**Methods:**
- **Geo holdout:** Run ads in one market (e.g., Dallas), not another (Houston). Compare conversion rates.
- **Audience holdout:** 90% test / 10% control. Track conversions in both groups.
- **Platform pause:** Pause all Meta ads for 2 weeks. Revenue drop = Meta's incremental contribution.

| Campaign Type | Typical Incrementality |
|---------------|----------------------|
| Retargeting (hot) | 20-40% |
| Retargeting (warm) | 40-60% |
| Prospecting (lookalike) | 60-80% |
| Prospecting (broad) | 70-90% |

Retargeting has the lowest incrementality — many of those users would have purchased anyway. **When to run:** Before major budget increases, quarterly, when stakeholders question ROI, after strategy changes.

## Lift Studies (Meta's Official Method)

**Conversion Lift:** Randomized control trial measuring additional conversions. Requires $30K+ spend, 2-4 week test, requested via Meta rep or Experiments hub.

**Brand Lift:** Survey-based. Measures awareness, consideration, recall. Best for brand campaigns.

```
Test Group: 1,000 conversions | Control: 400 | Lift: 150%
Incremental: 600 | Spend: $30K | Cost Per Incremental: $50
```

**Key metrics:** Lift %, Incremental Conversions, Incremental ROAS, Cost Per Incremental Conversion.

**Limitations:** Expensive, time-consuming, snapshot only, Meta-conducted (potential bias).

## Marketing Mix Modeling (MMM)

Statistical regression analysis of how all channels contribute to revenue. No pixel required; works across channels; accounts for offline impact; long-term view.

**Limitations:** Requires 2+ years of data; expensive; results lag; doesn't capture creative differences.

**Robyn** — Meta's free open-source MMM tool (R-based). Best for $100K+/month multi-channel advertisers. [github.com/facebookexperimental/Robyn](https://github.com/facebookexperimental/Robyn)

## Third-Party Attribution Tools

| Tool | Focus | Pricing |
|------|-------|---------|
| Triple Whale | Ecommerce, first-party pixel, post-purchase surveys | $129-$279/mo |
| Northbeam | Multi-touch, ML attribution | $500+/mo |
| Rockerbox | Enterprise, TV/offline integration | Enterprise |
| Dreamdata | B2B account-based | $599-$999/mo |
| HockeyStack | B2B/SaaS, intent signals | Custom |

**Must-haves:** First-party tracking (bypasses iOS/cookie issues), CRM integration, survey integration.

**Post-purchase surveys** — ask "How did you hear about us?" Zero-party data, works despite tracking limits, captures word-of-mouth. Limitation: memory and first-touch bias.

## How to Actually Measure Meta Impact

Use multiple methods — no single source is perfect:

1. Platform Reporting (directional, inflated, but detailed)
2. Third-Party Attribution (more accurate, still imperfect)
3. Post-Purchase Surveys (direct customer input)
4. Incrementality Tests (true causal impact)
5. Business Metrics (did revenue actually increase?)

**MER (Marketing Efficiency Ratio):**

```
MER = Total Revenue / Total Marketing Spend
```

Tracks business-wide efficiency instead of platform ROAS. Reduces attribution arguments, focuses on outcomes.

| Metric | What It Tells You |
|--------|-------------------|
| Meta-Reported ROAS | Platform-specific (inflated) |
| Blended ROAS | All marketing combined (realistic) |
| True ROAS | After incrementality adjustment |

**Monthly:** Compare Meta-reported vs third-party vs survey vs CRM conversions. Use conservative number for planning; platform data for optimization.

**Quarterly reality check:** (1) If I turned off Meta ads, what would happen? (2) Are new customers actually coming from Meta? (3) Is business growing proportionally to spend? (4) What do best customers say about how they found you?

## Settings Cheat Sheet

| Use Case | Window | Verification |
|----------|--------|-------------|
| Ecommerce (1-7 day cycle) | 7-day click, 1-day view | Triple Whale + blended ROAS |
| Lead gen (7-30 day cycle) | 7-day click only | CRM lead-to-customer rate |
| B2B SaaS (30-180 day cycle) | 28-day click (API) | Dreamdata / HockeyStack |
| Brand awareness | 1-day view | Brand lift study + surveys |

## Key Takeaways

1. Platform data is directional, not gospel — use for optimization, not truth
2. Click-through > view-through for conservative measurement (iOS changes make view-through less reliable)
3. Incrementality is the gold standard — run tests quarterly
4. Use multiple measurement methods — cross-reference everything
5. Focus on business outcomes — MER and blended metrics matter more than platform ROAS

---

*Next: [Account Structure Philosophy](account-structure.md)*

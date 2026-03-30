# How Meta's Algorithm Actually Works

## The Auction System

Every ad impression triggers an auction. Winner = highest **Total Value**:

```text
Total Value = Bid × Estimated Action Rate × Ad Quality
```

**Bid strategies:** Lowest Cost (default), Cost Cap, Bid Cap, ROAS Target.

**Estimated Action Rate (EAR)** — Meta's ML prediction of conversion probability. Inputs:
- **User data**: demographics, interests, purchase history, device patterns, social connections
- **Ad data**: account history, creative content analysis, landing page quality, CAPI/Pixel data
- **Contextual data**: time of day, seasonality, competitive landscape

**Ad Quality** — engagement minus negative feedback. Positive: likes, shares, watch time, CTR. Negative: "hide ad", reports, misleading claims, policy violations, high bounce rate.

**Auction example:**

```text
Ad A: $3 bid × 2% EAR × 0.8 quality = 0.048
Ad B: $2 bid × 3% EAR × 1.0 quality = 0.060  ← wins despite lowest bid
Ad C: $5 bid × 1% EAR × 0.7 quality = 0.035
```

**Implications:** Better creative lowers effective cost. Poor ads cost MORE. Relevance beats budget.

**Help the algorithm:** Clear conversion signals (Pixel + CAPI); consistent creative; quality data (customers, not just leads); sufficient run time; don't fragment budgets or over-narrow targeting.

## The Learning Phase

On launch or significant changes, Meta builds a new prediction model. **Exit:** 50 optimization events in 7 days OR 7 days elapsed. Expect 20–50% higher CPAs and inconsistent delivery during learning.

**Learning Limited** — not enough optimization events. Causes and fixes:

| Problem | Solution |
|---------|----------|
| Budget too low | Increase daily budget |
| Audience too narrow | Broaden targeting |
| Optimization event too rare | Optimize for higher-funnel event |
| Too many ad sets | Consolidate |

**What resets learning phase:**

| Change | Resets? |
|--------|---------|
| New ad | No (ad set level) |
| Budget change >20% | Sometimes |
| Budget change ≤20% | No |
| Targeting change | Yes |
| Optimization event change | Yes |
| Bid strategy change | Yes |
| All creatives changed | Yes |
| Pause >7 days | Yes |

**Best practice:** Make changes ≤20% and wait 2–3 days between adjustments.

## Account History & Trust

Established accounts: faster learning, better predictions, delivery priority, lower CPMs, feature access. New accounts: longer learning, higher initial CPAs, more scrutiny.

**Build trust:** Consistent spend, low refund/chargeback rates, policy compliance, positive engagement, clean payment history.

**Season new accounts:** $50–100/day for 2–4 weeks; quality conversions; avoid policy-edge content.

## Pixel Data & Its Impact

Each Pixel fire trains Meta on conversions, content preferences, timing, and device/placement signals.

**Essential events (in priority order for AEM):**

| Priority | Event | Purpose |
|----------|-------|---------|
| 1 | Purchase | Conversion signal |
| 2 | InitiateCheckout | High intent |
| 3 | AddToCart | Purchase intent |
| 4 | Lead | Lead capture |
| 5 | CompleteRegistration | Signup tracking |
| 6 | ViewContent | Interest signals |
| 7 | PageView | Basic tracking |
| 8 | (Custom) | — |

**Healthy pixel:** Events firing consistently, match rates >80%, no duplicates, proper value/currency passing.

**Common issues:** Duplicate events, missing parameters, delayed firing after redirect, cross-domain pixel conflicts.

## Aggregated Event Measurement (AEM)

Apple's iOS 14+ forced Meta to AEM: 8 events max per domain, 72-hour delayed reporting, ~20–30% modeled conversions, no user-level data.

**Working within AEM:** Verify domain in Business Settings. Rank 8 events by importance — only highest priority counts per user. Compare trends, not absolutes (~70–80% directly tracked, ~20–30% modeled).

## Conversion API (CAPI)

CAPI sends conversion data server-to-server, bypassing ad blockers (20–30% of users), iOS ATT (80%+ opt-out), and browser privacy restrictions.

**Use Pixel + CAPI together** — Meta deduplicates via `event_id`:

```text
User converts → Pixel fires (client) + CAPI fires (server) → Meta deduplicates → 1 conversion recorded
```

**Implementation options:**

| Method | Complexity | Cost | Reliability |
|--------|------------|------|-------------|
| Shopify/WooCommerce native | Easy | Free | Good |
| GTM server-side | Medium | ~$100/mo | Great |
| Custom server integration | Hard | Dev time | Best |
| Third-party (Segment, etc.) | Medium | $200+/mo | Great |

**Required CAPI parameters:** `event_name`, `event_time`, `action_source`, `event_source_url`, `user_data` (hashed: `em`, `ph`, `fn`, `ln`; cookies: `fbp`, `fbc`). Higher match rate = better optimization. Check quality: Events Manager → Data Sources → Pixel → Overview.

## The 2026 Algorithm Reality

**The shift:** Manual interest/behavior targeting → broad targeting with AI finding buyers. Creative IS targeting now.

**What this means:** Broad audiences often beat detailed targeting. Creative drives 70–80% of performance. CAPI is mandatory — conversion quality > quantity. Think systems: Testing → Scaling → Retargeting.

**Advantage+ features:**

| Feature | What It Does | When to Use |
|---------|--------------|-------------|
| Advantage+ Audience | AI finds your audience | Most campaigns |
| Advantage+ Placements | AI chooses placements | Always |
| Advantage+ Creative | AI tests variations | When you have volume |
| Advantage+ Shopping | Full auto ecom | Ecom with 50+ purchases/week |

Manual targeting wins for: niche B2B, controlled creative testing, specific placement requirements, limited conversion data.

---

*Next: [Attribution & Measurement](attribution.md)*

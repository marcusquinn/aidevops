# How Meta's Algorithm Actually Works

## The Auction System

Every ad impression triggers an auction. Winner = highest **Total Value**:

```
Total Value = Bid × Estimated Action Rate × Ad Quality
```

**Bid strategies:** Lowest Cost (default), Cost Cap, Bid Cap, ROAS Target.

**Estimated Action Rate (EAR)** — Meta's ML prediction that this user will convert on this ad. Inputs: campaign history, user behavior, creative, landing page, time/device/placement, and hundreds more signals. This is why creative matters so much.

ML prediction draws on three data categories:
- **User data**: demographics, interests, purchase history, device patterns, social connections
- **Ad data**: account history, creative content analysis, landing page quality, CAPI/Pixel data
- **Contextual data**: time of day, seasonality, competitive landscape

**Ad Quality** — engagement minus negative feedback. Positive: likes, shares, watch time, CTR. Negative: "hide ad", reports, misleading claims, policy violations, high bounce rate.

**Auction example:**

```
Ad A: $3 bid × 2% EAR × 0.8 quality = 0.048
Ad B: $2 bid × 3% EAR × 1.0 quality = 0.060  ← wins despite lowest bid
Ad C: $5 bid × 1% EAR × 0.7 quality = 0.035
```

**Implications:** Better creative lowers effective cost. Poor ads cost MORE to deliver. Relevance beats budget.

**Help the algorithm learn:**
- Give it clear conversion signals (Pixel + CAPI)
- Use consistent creative so it learns what works
- Feed quality data (good customers, not just leads)
- Let campaigns run long enough to learn
- Don't fragment budgets; don't fight it with overly narrow targeting

## The Learning Phase

On launch or significant changes, Meta enters a Learning Phase to build a prediction model for your ad.

**Exit criteria:** 50 optimization events in 7 days, OR 7 days elapsed. Expect 20–50% higher CPAs and inconsistent performance during learning.

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

Established accounts get faster learning, better predictions, delivery priority, lower CPMs, and feature access. New accounts face longer learning, higher initial CPAs, and more scrutiny.

**Build trust:** Consistent spend, low refund/chargeback rates, policy compliance, positive engagement, successful payment history.

**Seasoning new accounts:** Start at $50–100/day, run 2–4 weeks before aggressive scaling, focus on quality conversions, avoid policy-edge content initially.

## Pixel Data & Its Impact

Every Pixel fire teaches Meta what converts, what doesn't, content preferences, timing patterns, and device/placement signals.

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

**Working within AEM:** Verify your domain in Business Settings. Rank your 8 events by business importance — if a user completes multiple events, only the highest priority counts. Compare trends, not absolute numbers (~70–80% directly tracked, ~20–30% statistically modeled).

## Conversion API (CAPI)

CAPI sends conversion data server-to-server, bypassing ad blockers (20–30% of users), iOS ATT (80%+ opt-out), and browser privacy features.

**Use Pixel + CAPI together** — Meta deduplicates via `event_id`:

```
User converts → Pixel fires (client) + CAPI fires (server) → Meta deduplicates → 1 conversion recorded
```

**Implementation options:**

| Method | Complexity | Cost | Reliability |
|--------|------------|------|-------------|
| Shopify/WooCommerce native | Easy | Free | Good |
| GTM server-side | Medium | ~$100/mo | Great |
| Custom server integration | Hard | Dev time | Best |
| Third-party (Segment, etc.) | Medium | $200+/mo | Great |

**Required CAPI parameters:** `event_name`, `event_time`, `action_source`, `event_source_url`, `user_data` (hashed: `em`, `ph`, `fn`, `ln`; cookies: `fbp`, `fbc`). Higher match rate = better optimization.

Check CAPI quality in Events Manager → Data Sources → Select Pixel → Overview.

## The 2026 Algorithm Reality

**The shift:** Manual interest/behavior targeting → broad targeting with AI finding buyers. Creative IS targeting now.

**What this means:**
1. Broad audiences often beat detailed targeting — let the algorithm learn from conversion data
2. Creative quality drives 70–80% of performance — algorithm optimizes delivery, you control the message
3. CAPI is mandatory — first-party data is gold, conversion quality > quantity
4. Think systems: Testing → Scaling → Retargeting as a continuous loop

**Advantage+ features:**

| Feature | What It Does | When to Use |
|---------|--------------|-------------|
| Advantage+ Audience | AI finds your audience | Most campaigns |
| Advantage+ Placements | AI chooses placements | Always |
| Advantage+ Creative | AI tests variations | When you have volume |
| Advantage+ Shopping | Full auto ecom | Ecom with 50+ purchases/week |

Manual targeting still wins for: very niche B2B, creative testing requiring control, specific placement requirements, limited conversion data.

---

*Next: [Attribution & Measurement](attribution.md)*

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# How Meta's Algorithm Actually Works

## The Auction System

Every impression triggers an auction. Winner = highest **Total Value**:

```text
Total Value = Bid × Estimated Action Rate × Ad Quality
```

**Bid strategies:** Lowest Cost (default), Cost Cap, Bid Cap, ROAS Target.

**Estimated Action Rate (EAR)** — ML prediction of conversion probability. Inputs: user data (demographics, interests, purchase history, device, social), ad data (account history, creative analysis, landing page, CAPI/Pixel), contextual data (time, seasonality, competition).

**Ad Quality** — engagement minus negative feedback. Positive: likes, shares, watch time, CTR. Negative: "hide ad", reports, misleading claims, policy violations, high bounce.

**Auction example:** Ad B ($2 bid × 3% EAR × 1.0 quality = 0.060) wins over Ad A ($3 bid × 2% EAR × 0.8 quality = 0.048) and Ad C ($5 bid × 1% EAR × 0.7 quality = 0.035).

**Implications:** Better creative lowers cost. Poor ads cost MORE. Relevance beats budget.

**Optimization:** Clear conversion signals (Pixel + CAPI); consistent creative; quality data (customers, not just leads); sufficient run time; avoid budget fragmentation or over-narrow targeting.

## The Learning Phase

On launch or significant changes, Meta builds a new prediction model. **Exit:** 50 optimization events in 7 days OR 7 days elapsed. Expect 20–50% higher CPAs and inconsistent delivery.

**Learning Limited** — insufficient optimization events:
- **Budget too low:** Increase daily budget.
- **Audience too narrow:** Broaden targeting.
- **Optimization event too rare:** Optimize for higher-funnel event.
- **Too many ad sets:** Consolidate.

**What resets learning:**
- **Yes:** Targeting change, Optimization event change, Bid strategy change, All creatives changed, Pause >7 days.
- **Sometimes:** Budget change >20%.
- **No:** New ad (ad set level), Budget change ≤20%.

**Best practice:** Changes ≤20%, wait 2–3 days between adjustments.

## Account History & Trust

Established accounts: faster learning, better predictions, delivery priority, lower CPMs, feature access. New accounts: longer learning, higher initial CPAs, more scrutiny.

**Build trust:** Consistent spend, low refund/chargeback rates, policy compliance, positive engagement, clean payment history.

**Seasoning:** $50–100/day for 2–4 weeks; quality conversions; avoid policy-edge content.

## Pixel Data & Its Impact

Each Pixel fire trains Meta on conversions, content preferences, timing, and device/placement signals.

**Essential events (AEM priority):**
1. **Purchase:** Conversion signal.
2. **InitiateCheckout:** High intent.
3. **AddToCart:** Purchase intent.
4. **Lead:** Lead capture.
5. **CompleteRegistration:** Signup tracking.
6. **ViewContent:** Interest signals.
7. **PageView:** Basic tracking.

**Healthy pixel:** Events firing consistently, match rates >80%, no duplicates, proper value/currency passing. Avoid duplicate events, missing parameters, delayed firing after redirect, cross-domain conflicts.

## Aggregated Event Measurement (AEM)

iOS 14+ forced AEM: 8 events max per domain, 72-hour delayed reporting, ~20–30% modeled conversions, no user-level data.

**Working within AEM:** Verify domain in Business Settings. Rank 8 events by importance — only highest priority counts per user. Compare trends, not absolutes (~70–80% tracked, ~20–30% modeled).

## Conversion API (CAPI)

Server-to-server conversion data, bypassing ad blockers (20–30% of users), iOS ATT (80%+ opt-out), and browser privacy restrictions.

**Use Pixel + CAPI together** — Meta deduplicates via `event_id`.

**Implementation options:**
- **Easy:** Shopify/WooCommerce native (Free, Good).
- **Medium:** GTM server-side (~$100/mo, Great) or Third-party (Segment, etc., $200+/mo, Great).
- **Hard:** Custom server integration (Dev time, Best).

**Required parameters:** `event_name`, `event_time`, `action_source`, `event_source_url`, `user_data` (hashed: `em`, `ph`, `fn`, `ln`; cookies: `fbp`, `fbc`). Higher match rate = better optimization. Check: Events Manager → Data Sources → Pixel → Overview.

## The 2026 Algorithm Reality

**The shift:** Manual interest/behavior targeting → broad targeting with AI finding buyers. Creative IS targeting.

**What this means:** Broad audiences often beat detailed targeting. Creative drives 70–80% of performance. CAPI mandatory — conversion quality > quantity. Think systems: Testing → Scaling → Retargeting.

**Advantage+ features:**
- **Advantage+ Audience:** AI finds your audience (Most campaigns).
- **Advantage+ Placements:** AI chooses placements (Always).
- **Advantage+ Creative:** AI tests variations (When you have volume).
- **Advantage+ Shopping:** Full auto ecom (Ecom with 50+ purchases/week).

Manual targeting wins for: niche B2B, controlled creative testing, specific placement requirements, limited conversion data.

*Next: [Attribution & Measurement](attribution.md)*

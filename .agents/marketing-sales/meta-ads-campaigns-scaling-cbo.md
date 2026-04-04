<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Scaling Campaign (CBO)

**Why CBO?** ABO requires manual budget allocation; CBO auto-allocates to best performers 24/7.

**Principles:** Only proven winners enter. Trust the algorithm. Scale gradually (big jumps reset learning). Don't touch winning ads.

## Moving Winners from Testing

| Tier | CPA | Conversions | CTR |
|------|-----|-------------|-----|
| Minimum | At/below target, 3+ days | 50+ | >0.8% |
| Ideal | 20%+ below target | 100+ | >1.5% |

**Duplicate Ad Set (recommended)** — preserves pixel learning. Winning ad set → Duplicate → select Scale campaign → turn ON in scale, OFF in testing.

**Duplicate Ad Only** — adding a variation to an existing scale ad set.

**Post-move:** Watch delivery first 48h. Drop → give 3-5 days (learning reset). Still poor after 5 days → duplicate fresh.

## Broad Targeting (2026)

Meta's AI outperforms manual targeting. Broad = algorithm finds converters from millions of signals.

**Use Broad:** 50+ conversions/week, strong pixel data, strong creative, scaling.
**Use Interests/Lookalikes:** Very niche B2B, new account, <50 conversions/week, compliance restrictions.

```text
Location: [Target geography]
Age: 18-65+ (or 25-65+ for adult products)
Gender: All
Detailed Targeting: NONE
Advantage+ Audience: ON
```

**Geo tiers:** Tier 1 (start here): US, CA, UK, AU. Tier 2 (if Tier 1 saturates): Western Europe, Nordics. Never mix dramatically different geos in one ad set.

**Age/Gender:** Only restrict when legally required or clear buyer skew (alcohol → 21+, menstrual products → female).

## CBO Budget Management

CBO evaluates hourly. Example at $1,000/day: $20 CPA ad set → $500 | $30 CPA → $300 | $50 CPA → $200.

**Minimum budget:** `Target CPA × 10` per ad set. 3 ad sets at $30 CPA → $900+ campaign budget.
**Minimum spend limits:** `Target CPA × 3-5` — forces CBO to give new ad sets fair chance against established ones.

| Symptom | Cause | Fix |
|---------|-------|-----|
| One ad set gets all spend | Winner dominates | Minimum spend limits |
| New ad sets get nothing | Established preferred | Duplicate to fresh campaign |
| Performance volatility | Too few ad sets | Add more proven winners |
| CPA rising | Winner fatigue | Refresh creative |

## Scaling Methods

### Vertical (Budget Increases)

| Situation | Can Exceed 20%? |
|-----------|-----------------|
| Learning complete, CPA stable | Yes, 30-50% |
| CPA significantly below target | Yes, 50%+ |
| Learning phase | No, conservative |
| CPA near target | No, 20% max |

**Timing:** Morning (12:00-1:00 AM). Avoid mid-day.
**Conservative:** $100 → $120 → $144 → $173 → $207 → $249 (every 2 days).
**Aggressive:** $100 → $200 → monitor → $400 if CPA holds.

### Horizontal (Duplication)

When vertical hits limits or to spread risk. Change ONE variable per duplicate:

```text
Original: Broad US, 25-65
Dup 1: Broad US, 25-45    Dup 2: Broad US, 45-65
Dup 3: Broad CA/UK/AU     Dup 4: 1% Lookalike
```

Max 5-6 similar ad sets (internal competition). Start with 2-3.

### New Creatives (Safest)

Test in ABO → find winner → add to existing winning scale ad set. No learning reset; creative diversity fights fatigue.

### Scaling Sequence

1. **Vertical:** $200 → $300-400 (wk 1) → $500-600 (wk 2), watch CPA
2. **Horizontal:** CPA rises at $600 → duplicate (2 × $400 > 1 × $800 for stability)
3. **Creative:** Continuously test in ABO, add winners, retire fatigued

## Performance Diagnostics

| Symptom | Cause | Action |
|---------|-------|--------|
| CPM rising | Competition or quality issue | Review ad quality, check auction overlap |
| CTR declining | Creative fatigue | Refresh creative |
| CVR declining | Landing page or offer issue | Test landing page |
| Frequency >3 | Audience saturation | Expand audience |
| Sudden CPA spike | Algorithm reset/competition | Wait 48h |
| Gradual CPA rise | Creative fatigue | New creative |

**Fatigue signals:** CTR declining week-over-week, frequency >2.5-3.0, CPA rising while CPM stable, same creative 3+ weeks. **Refresh** if 1-2 ads fatigued (add new). **Kill** if all fatigued, CPA 50%+ above target sustained.

### Seasonal CPM

| Period | CPM Change | Action |
|--------|-----------|--------|
| Q4 (Oct-Dec) | +30-100% | Raise CPA targets or scale back |
| Black Friday | +100-200% | Only if ROAS covers |
| January | -20-30% | Good time to scale |
| Summer | Variable | Test aggressively |

## Advantage+ Shopping (ASC)

Fully automated: Meta controls targeting, creative combos, prospecting + retargeting.

**Use ASC:** Ecommerce with catalog, 50+ purchases/week, 10+ creatives, want simplicity.
**Use Manual:** B2B/lead gen, specific targeting, low volume, testing creative.

**Setup:** Customer Budget Cap 0-20% (0% = prospecting only). Min 5 ads (ideal 10+), mix formats. One ASC per country.

| Metric | ASC | Manual |
|--------|-----|--------|
| CPA | 10-20% lower | Baseline |
| Scale | High | Medium |
| Control | Low | High |
| Setup | Minutes | Hours |

## Checklist

**Pre-scale:** 50+ conversions, CPA at/below target 3+ days, no creative fatigue, stable landing page.
**Launch:** Duplicate ad set (don't recreate), match testing audience, start at testing budget, set minimum spend limits.
**Monitor:** Daily first week, track CPA trend not single days, scale 20% increments, refresh creative before fatigue.
**Warning signs:** CPA +20% sustained, frequency >3.0, CTR declining weekly, unexplained CPM spike.
**Limits:** Know max budget, don't scale into loss, maintain creative pipeline, plan for seasonal CPM shifts.

---

*Next: [Retargeting Campaign](retargeting.md)*

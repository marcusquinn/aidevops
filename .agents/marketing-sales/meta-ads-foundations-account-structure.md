# Account Structure Philosophy

Account structure determines algorithm performance. Simplified structures win in 2026 — Meta's AI outperforms manual segmentation when given enough data.

## Hierarchy

```
Business Account
└── Ad Account(s)
    └── Campaign(s)       ← Objective, buying type, CBO budget
        └── Ad Set(s)     ← Audience, placements, schedule, ABO budget, bid strategy
            └── Ad(s)     ← Creative, copy, headline, CTA, destination URL
```

## Simplified vs Granular

Each ad set needs ~50 conversions/week to exit learning phase.

| Structure | Ad Sets | Daily Budget | Conversions/Week | Result |
|-----------|---------|--------------|------------------|--------|
| Granular (10 ad sets) | 10 x $50 | $500 | ~12/ad set | All learning-limited |
| Simplified (3 ad sets) | 3 x $165 | $495 | ~39/ad set | Closer to exiting learning |

**Use granular when:** truly different audiences (US vs EU), different products/buyers, different offers, or A/B testing specific variables.

## Power 5 to 2026 Evolution

| Original (2019-2022) | 2026 Equivalent |
|----------------------|-----------------|
| Account Simplification | Consolidation — fewer campaigns, more budget per campaign |
| CBO | Use contextually (not always) |
| Automatic Placements | Advantage+ Placements |
| Auto Advanced Matching | CAPI (now mandatory) |
| Dynamic Ads | Advantage+ Shopping/Creative |

## Consolidation

**Why:** more conversions per ad set -> faster learning -> lower CPMs -> less internal competition.

**Before vs After (same $300/day budget):**

| Setup | Ad Sets | Conversions/Week | Outcome |
|-------|---------|------------------|---------|
| 3 campaigns x 5 ad sets | 15 | ~5/ad set | All learning-limited |
| Testing (ABO 3 sets) + Scale (CBO 2 sets) | 5 | ~8-24/ad set | Better distributed |

**Consolidate when:** same objective, similar audiences, same funnel stage, overlap >30%, or any ad set gets <50 conversions/week.

**Split when:** different objectives, different funnel stages (prospecting vs retargeting), different products/geographies, or testing vs scaling.

**Audience overlap check:** Ads Manager -> Audiences -> select 2+ -> ... -> "Show Audience Overlap". If >30%, consolidate or exclude.

## CBO vs ABO

| | CBO (Campaign Budget) | ABO (Ad Set Budget) |
|--|----------------------|---------------------|
| Budget control | Meta distributes to winners | You set per ad set |
| Best for | Scaling proven winners | Creative testing |
| Downside | Some ad sets get starved | Manual management |

**Workflow:** test in ABO -> identify winners (3+ days good CPA) -> duplicate into CBO -> scale CBO -> kill ABO losers -> add new tests -> repeat.

## 2026 Optimal Structure

```
AD ACCOUNT
├── Campaign 1: CREATIVE TESTING (ABO) — 15-20% of budget
│   ├── Ad Set: Angle A → 1-2 ads
│   ├── Ad Set: Angle B → 1-2 ads
│   └── Ad Set: Angle C → 1-2 ads
│
├── Campaign 2: SCALE (CBO) — 60-70% of budget
│   ├── Ad Set: Proven Winner A (Broad) → 3-5 ads
│   ├── Ad Set: Proven Winner B (Broad) → 3-5 ads
│   └── Ad Set: Lookalike (if needed) → 3-5 ads
│
└── Campaign 3: RETARGETING (CBO or ABO) — 15-25% of budget
    ├── Ad Set: Website Visitors 7d → 2-3 ads
    ├── Ad Set: Engagers 30d → 2-3 ads
    └── Ad Set: Cart Abandoners → 2-3 ads
```

**Advantage+ Shopping (ecommerce):** replace Campaign 2 with ASC (combines prospecting + retargeting). Separate retargeting campaign may not be needed.

### Naming Convention

```
Campaign: [OBJECTIVE]_[TYPE]_[AUDIENCE]_[DATE]
  e.g.  PURCH_TESTING_BROAD_2026-02
        PURCH_SCALE_LAL1_2026-02

Ad Set:   [AUDIENCE]_[ANGLE]
  e.g.  BROAD_PainPoint, LAL1%_Testimonial

Ad:       [FORMAT]_[HOOK]_[VERSION]
  e.g.  VID_PainPoint_v1, IMG_Comparison_v2
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| 10+ campaigns, fragmented budget | Consolidate to 2-3 campaigns |
| 10+ ad sets per campaign, none learning | Max 3-5 ad sets per campaign |
| CBO for testing (winners starve new creative) | ABO for testing, CBO for scaling |
| Mixed objectives in one campaign | One objective per campaign |
| Retargeting mixed with prospecting | Separate retargeting campaign |
| Duplicate audiences competing | Check overlap, consolidate or exclude |

*Next: [Glossary](glossary.md)*

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Decision Trees — When to Use What

> Visual decision frameworks for the most common Meta Ads questions.

## Campaign Type Selection

```text
What am I trying to achieve?
│
├── Sell products online?
│   ├── 100+ purchases/week? → Advantage+ Shopping (ASC)
│   ├── 50-100 purchases/week? → Manual CBO + Retargeting
│   └── <50 purchases/week? → Manual ABO, optimize higher funnel
│
├── Generate leads?
│   ├── B2B/SaaS?
│   │   ├── High volume → CBO with broad + retargeting
│   │   └── Low volume → ABO testing, nurture funnel
│   └── B2C leads? → CBO with broad + instant forms
│
├── App installs? → App promotion objective + Advantage+
├── Drive traffic? → Traffic objective (but: is traffic the real goal?)
└── Build awareness? → Awareness objective OR video views for retargeting pool
```

## Budget Type: CBO vs ABO

```text
├── Testing new creative? → ABO (even budget distribution)
├── Scaling proven winners? → CBO (let Meta optimize)
├── Testing new audiences? → ABO (control per audience)
├── Running retargeting?
│   ├── Sequential messaging? → ABO
│   └── Simple retargeting? → CBO
│
└── Special cases:
    ├── One ad set only? → Doesn't matter (same result)
    ├── Very different audience sizes? → ABO (CBO starves small audiences)
    └── Need minimum spend guarantees? → ABO with set budgets
```

## Audience Selection

```text
├── Have 100+ conversions?
│   ├── Built lookalike?
│   │   ├── No → Build 1% lookalike from best customers
│   │   └── Yes → Test LAL vs Broad
│   └── Try broad + Advantage+ Audience
│
├── <100 conversions?
│   ├── Have customer list? → Upload + build LAL
│   └── No list? → Start with interest targeting
│
├── B2B/Niche product?
│   ├── Can define job titles? → Layer job + interests
│   └── Too niche? → Consider LinkedIn instead
│
└── Retargeting:
    ├── Have website traffic? → Create custom audiences
    ├── Have engagement? → Video viewers, page engagers
    └── Have customer list? → Upload for exclusions + upsell
```

## Creative Format Selection

```text
├── Physical product (ecom)?
│   ├── Hero product → UGC unboxing, product demo
│   ├── Multiple products → Carousel, collection
│   └── Complex product → Explainer video
│
├── Service/SaaS?
│   ├── Visual product → Screen recording, demo
│   ├── Abstract benefit → Testimonial, results
│   └── Personal service → Founder talking head
│
├── Information/Content? → Educational video, carousel breakdown
│
├── Competitors? → Check Ad Library for format trends
│
└── Resource constraints:
    ├── Video production capability? → Prioritize video
    ├── UGC creators available? → UGC content
    ├── Strong product photos? → Static images
    └── Design only? → Graphic statics, carousels
```

## Ad Lifecycle: Test → Keep/Kill → Scale

### Testing phase

```text
├── New creative concept? → Test in ABO first
├── Variation of winner? → Add to existing ad set
│
└── Evaluate after data accumulates:
    ├── 0-20 conversions → Still learning, keep testing
    ├── 20-50 conversions:
    │   ├── CPA ≤ target? → Consider graduating to scale
    │   └── CPA > 1.5x target? → Kill it
    └── 50+ conversions:
        ├── CPA ≤ target, stable? → Graduate to scale
        └── Not winning? → Kill, analyze, iterate
```

### Kill vs keep

```text
By duration:
├── <3 days:
│   ├── Zero conversions, high spend? → Kill
│   ├── Promising signals? → Keep testing
│   └── Unclear? → Wait until day 3
├── 3-7 days:
│   ├── CPA > 2x target? → Kill
│   ├── CPA 1.5-2x target? → Consider killing or iterating
│   ├── CPA 1-1.5x target? → Keep, monitor
│   └── CPA ≤ target? → Winner, consider scaling
└── 7+ days:
    ├── Still in learning? → Needs more budget or consolidation
    ├── CPA > 1.5x target? → Kill
    └── CPA ≤ target? → Scale

By trend:
├── Improving day over day? → Keep (even if above target)
├── Declining? → Kill soon
└── Stable? → Evaluate against target

Fatigue check:
├── Frequency > 3, CTR declining? → Refresh creative or kill
└── Frequency < 3, stable? → Keep going
```

### Scaling method

```text
Budget increase rate (based on CPA headroom):
├── CPA 50%+ below target → Aggressive (50%+ budget increase)
├── CPA 20-50% below target → Moderate (20-30% increases)
└── CPA near target → Conservative (10-20% increases)

Vertical vs horizontal:
├── CPA rising with budget increases? → Horizontal (duplicate ad sets)
└── CPA stable? → Continue vertical scaling

Pre-scale checks:
├── CTR declining? → Add new creative before scaling more
└── Frequency > 3 in prospecting? → Broaden audience or duplicate
```

## Troubleshooting: Campaign Not Performing

```text
├── Not spending?
│   ├── Check payment method
│   ├── Check ad approval status
│   ├── Check budget (too low?)
│   └── Check schedule (future start date?)
│
├── CPM > $30?
│   ├── Narrow audience → Broaden targeting
│   ├── Low quality ad → Improve creative
│   └── High competition period → Adjust expectations
│
├── CTR < 0.5%? (CPM reasonable)
│   ├── Creative not compelling → Test new hooks
│   ├── Wrong audience → Adjust targeting
│   └── Offer not resonating → Test new angle
│
├── Landing Page Views << Link Clicks? (CTR > 1%)
│   ├── Page load slow → Speed up page
│   ├── Page broken → Fix technical issues
│   └── Tracking issue → Check pixel
│
└── CVR < 2%? (page loading fine)
    ├── Landing page doesn't match ad → Improve congruence
    ├── Offer not compelling → Improve offer
    ├── Too much friction → Simplify form/checkout
    └── Wrong traffic → Adjust targeting
    (CVR > 5% = everything working, need more volume)
```

## Platform Comparison

```text
By product type:
├── B2C visual product → Meta (strong)
├── B2C local service → Meta + Google
├── B2C impulse buy → Meta + TikTok
├── B2B SMB → Meta (cost-effective)
├── B2B Enterprise → LinkedIn (precise targeting)
├── B2B Mixed → Meta for awareness, LinkedIn for conversion
└── High-intent service → Google Search (intent-based)

By budget:
├── <$5K/month → Pick one platform, master it
├── $5-20K/month → Meta primary + one secondary
└── $20K+/month → Multi-platform strategy

By content strength:
├── Strong video → Meta, TikTok, YouTube
├── Strong written → Google, LinkedIn
└── Strong visual → Meta, Pinterest
```

---

*Back to: [meta-ads.md](meta-ads.md)*

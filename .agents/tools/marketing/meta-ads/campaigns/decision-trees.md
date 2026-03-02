# Decision Trees — When to Use What

> Visual decision frameworks for the most common Meta Ads questions.

---

## Campaign Type Selection

```
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
│   └── B2C leads?
│       └── CBO with broad + instant forms
│
├── Get app installs?
│   └── App promotion objective + Advantage+
│
├── Drive traffic?
│   └── Traffic objective (but consider: is traffic the real goal?)
│
└── Build awareness?
    └── Awareness objective OR video views for retargeting pool
```

---

## Budget Type Selection

```
Should I use CBO or ABO?
│
├── What's my goal?
│   │
│   ├── Testing new creative?
│   │   └── ABO (need even budget distribution)
│   │
│   ├── Scaling proven winners?
│   │   └── CBO (let Meta optimize)
│   │
│   ├── Testing new audiences?
│   │   └── ABO (control per audience)
│   │
│   └── Running retargeting?
│       ├── Sequential messaging? → ABO
│       └── Simple retargeting? → CBO
│
└── Special cases:
    ├── One ad set only? → Doesn't matter (same result)
    ├── Very different audience sizes? → ABO (CBO can starve small audiences)
    └── Need minimum spend guarantees? → ABO with set budgets
```

---

## Audience Selection

```
What audience should I target?
│
├── Do I have conversion data?
│   │
│   ├── 100+ conversions ever?
│   │   │
│   │   ├── Built lookalike? 
│   │   │   ├── No → Build 1% lookalike from best customers
│   │   │   └── Yes → Test LAL vs Broad
│   │   │
│   │   └── Try broad + Advantage+ Audience
│   │
│   └── <100 conversions?
│       ├── Have customer list? → Upload + build LAL
│       └── No list? → Start with interest targeting
│
├── B2B/Niche product?
│   ├── Can I define job titles? → Layer job + interests
│   └── Too niche? → Consider LinkedIn instead
│
└── What about retargeting?
    ├── Have website traffic? → Create custom audiences
    ├── Have engagement? → Video viewers, page engagers
    └── Have customer list? → Upload for exclusions + upsell
```

---

## Creative Format Selection

```
What format should I create?
│
├── What's my product?
│   │
│   ├── Physical product (ecom)?
│   │   ├── Hero product → UGC unboxing, product demo
│   │   ├── Multiple products → Carousel, collection
│   │   └── Complex product → Explainer video
│   │
│   ├── Service/SaaS?
│   │   ├── Visual product → Screen recording, demo
│   │   ├── Abstract benefit → Testimonial, results
│   │   └── Personal service → Founder talking head
│   │
│   └── Information/Content?
│       └── Educational video, carousel breakdown
│
├── What's working for competitors?
│   └── Check Ad Library for format trends
│
└── What do I have resources for?
    ├── Video production capability? → Prioritize video
    ├── UGC creators available? → UGC content
    ├── Strong product photos? → Static images
    └── Design only? → Graphic statics, carousels
```

---

## Testing vs Scaling Decision

```
Should I test or scale this ad?
│
├── Is this a new creative concept?
│   ├── Yes → Test in ABO first
│   └── No (variation of winner) → Add to existing ad set
│
├── How much data does it have?
│   │
│   ├── 0-20 conversions?
│   │   └── Still learning, keep testing
│   │
│   ├── 20-50 conversions?
│   │   ├── Promising (CPA ≤ target)? → Consider graduating
│   │   └── Poor (CPA > 1.5x target)? → Kill it
│   │
│   └── 50+ conversions?
│       ├── Winner (CPA ≤ target, stable)? → Graduate to scale
│       └── Not winning? → Kill, analyze, iterate
│
└── Is CPA meeting target?
    ├── Yes, for 3+ days → Scale it
    ├── Yes, but inconsistent → Wait for more data
    └── No → Kill or iterate
```

---

## Kill vs Keep Decision

```
Should I kill this ad/ad set?
│
├── How long has it been running?
│   │
│   ├── Less than 3 days?
│   │   ├── Zero conversions, high spend? → Kill
│   │   ├── Some promising signals? → Keep testing
│   │   └── Unclear? → Wait until day 3
│   │
│   ├── 3-7 days?
│   │   ├── CPA > 2x target? → Kill
│   │   ├── CPA > 1.5x target? → Consider killing or iterating
│   │   ├── CPA 1-1.5x target? → Keep, monitor
│   │   └── CPA ≤ target? → Winner, consider scaling
│   │
│   └── 7+ days?
│       ├── Still in learning? → Needs more budget or consolidation
│       ├── CPA > 1.5x target? → Kill
│       └── CPA ≤ target? → Scale
│
├── What's the trend?
│   ├── Improving day over day? → Keep (even if above target)
│   ├── Declining? → Kill soon
│   └── Stable? → Evaluate against target
│
└── Is there fatigue?
    ├── Frequency > 3, CTR declining? → Refresh creative or kill
    └── Frequency < 3, stable? → Keep going
```

---

## Scaling Method Selection

```
How should I scale this winner?
│
├── What's current performance?
│   │
│   ├── CPA 50%+ below target?
│   │   └── Aggressive scaling okay (50%+ budget increase)
│   │
│   ├── CPA 20-50% below target?
│   │   └── Moderate scaling (20-30% increases)
│   │
│   └── CPA near target?
│       └── Conservative scaling (10-20% increases)
│
├── Has vertical scaling hit limits?
│   │
│   ├── CPA rising with budget increases?
│   │   └── Try horizontal scaling (duplicate ad sets)
│   │
│   └── CPA stable?
│       └── Continue vertical scaling
│
├── Is creative fatiguing?
│   │
│   ├── CTR declining?
│   │   └── Add new creative before scaling more
│   │
│   └── CTR stable?
│       └── Continue scaling
│
└── Audience saturation?
    ├── Frequency > 3 in prospecting?
    │   └── Broaden audience or duplicate
    └── Frequency < 3?
        └── Continue current approach
```

---

## Troubleshooting Decision Tree

```
My campaign isn't performing. Why?
│
├── Is it spending?
│   │
│   ├── No spend at all?
│   │   ├── Check payment method
│   │   ├── Check ad approval status
│   │   ├── Check budget (too low?)
│   │   └── Check schedule (future start date?)
│   │
│   └── Spending but no results?
│       └── Continue below...
│
├── What's the CPM?
│   │
│   ├── CPM > $30?
│   │   ├── Narrow audience → Broaden targeting
│   │   ├── Low quality ad → Improve creative
│   │   └── High competition period → Adjust expectations
│   │
│   └── CPM reasonable (<$20)?
│       └── Issue is post-impression, continue...
│
├── What's the CTR?
│   │
│   ├── CTR < 0.5%?
│   │   ├── Creative not compelling → Test new hooks
│   │   ├── Wrong audience → Adjust targeting
│   │   └── Offer not resonating → Test new angle
│   │
│   └── CTR > 1%?
│       └── Creative working, issue is post-click...
│
├── Are clicks becoming visits?
│   │
│   ├── Landing Page Views << Link Clicks?
│   │   ├── Page load slow → Speed up page
│   │   ├── Page broken → Fix technical issues
│   │   └── Tracking issue → Check pixel
│   │
│   └── Landing Page Views ≈ Link Clicks?
│       └── Page loading, issue is conversion...
│
└── What's conversion rate?
    │
    ├── CVR < 2%?
    │   ├── Landing page doesn't match ad → Improve congruence
    │   ├── Offer not compelling → Improve offer
    │   ├── Too much friction → Simplify form/checkout
    │   └── Wrong traffic → Adjust targeting
    │
    └── CVR > 5%?
        └── Everything working, need more volume
```

---

## Platform Comparison

```
Should I use Meta or another platform?
│
├── What am I selling?
│   │
│   ├── B2C product/service?
│   │   ├── Visual product → Meta (strong)
│   │   ├── Local service → Meta + Google
│   │   └── Impulse buy → Meta + TikTok
│   │
│   ├── B2B SaaS/Service?
│   │   ├── SMB market → Meta (cost-effective)
│   │   ├── Enterprise → LinkedIn (precise targeting)
│   │   └── Mixed → Meta for awareness, LinkedIn for conversion
│   │
│   └── High-intent service?
│       └── Google Search (intent-based)
│
├── What's my budget?
│   │
│   ├── <$5K/month?
│   │   └── Pick one platform, master it
│   │
│   ├── $5-20K/month?
│   │   └── Meta primary + one secondary
│   │
│   └── $20K+/month?
│       └── Multi-platform strategy
│
└── What's my content strength?
    ├── Strong video capability? → Meta, TikTok, YouTube
    ├── Strong written content? → Google, LinkedIn
    └── Strong visual assets? → Meta, Pinterest
```

---

## Quick Reference Summary

### When to Use ABO
- Creative testing
- Audience testing
- Need budget control per ad set
- Sequential retargeting

### When to Use CBO
- Scaling proven winners
- Simple retargeting
- Want algorithmic optimization
- 2+ ad sets with similar audiences

### When to Use ASC
- Ecommerce only
- 100+ purchases/week
- 10+ creative variations
- Want hands-off automation

### When to Use Broad Targeting
- Have conversion history
- Want to scale
- Algorithm has learned your buyer

### When to Use Detailed Targeting
- New account/pixel
- Very niche product
- Compliance requirements
- Testing audience hypothesis

### When to Kill
- CPA > 2x target after 50+ spend
- CTR < 0.3% after 1K impressions
- No conversions after 2x CPA spend
- Declining trend for 5+ days

### When to Scale
- CPA ≤ target for 3+ days
- 50+ conversions
- Stable or improving trend
- Creative not fatigued

---

*Back to: [SKILL.md](../SKILL.md)*

# Account Structure Philosophy

> The way you organize your Meta ads account determines whether you succeed or waste money fighting the algorithm.

---

## Table of Contents
1. [The Hierarchy: Campaigns, Ad Sets, Ads](#the-hierarchy)
2. [Simplified vs Granular Structure](#simplified-vs-granular-structure)
3. [Power 5 Framework](#power-5-framework)
4. [Account Consolidation Benefits](#account-consolidation-benefits)
5. [When to Split vs Consolidate](#when-to-split-vs-consolidate)
6. [CBO vs ABO Deep Dive](#cbo-vs-abo-deep-dive)
7. [The 2026 Optimal Structure](#the-2026-optimal-structure)

---

## The Hierarchy

### How Meta Ads Are Organized

```
Business Account
└── Ad Account(s)
    └── Campaign(s)
        └── Ad Set(s)
            └── Ad(s)
```

### What Each Level Controls

**Campaign Level:**
- Objective (what you're optimizing for)
- Buying type (Auction, Reach & Frequency)
- Special ad categories
- Campaign budget (if using CBO)
- A/B testing
- Campaign spending limits

**Ad Set Level:**
- Audience targeting
- Placements
- Schedule (start/end dates, dayparting)
- Budget (if using ABO)
- Bid strategy
- Optimization goal
- Delivery type

**Ad Level:**
- Creative (image, video, carousel)
- Primary text (body copy)
- Headline
- Description
- Call to action
- Destination URL

### The Relationship

```
1 Campaign = 1 Objective
    ↓
1 Ad Set = 1 Audience + Budget combo
    ↓
Multiple Ads = Creative variations
```

---

## Simplified vs Granular Structure

### The Great Debate

**Granular Structure (Old School):**
- Many campaigns for different objectives
- Many ad sets for different audiences
- Detailed segmentation

**Simplified Structure (2026 Best Practice):**
- Few campaigns
- Broad audiences
- Let algorithm optimize

### Why Simplified Wins Now

**Meta's AI is smarter than manual segmentation.**

| You Think | Reality |
|-----------|---------|
| "I'll target 25-34 females" | Meta already knows who converts |
| "I'll separate interests" | Algorithm combines better than you |
| "I need 10 ad sets to test" | 3 ad sets with more budget learn faster |

### The Data Problem with Granular

Each ad set needs ~50 conversions/week to exit learning phase.

**Granular Example:**
- 10 ad sets × $50/day = $500/day = $3,500/week
- If CPA is $30, that's ~117 conversions/week total
- Only ~12 conversions per ad set
- Every ad set is in "Learning Limited" = poor performance

**Simplified Example:**
- 3 ad sets × $165/day = $495/day = $3,465/week
- Same CPA of $30 = ~116 conversions/week total
- ~39 conversions per ad set
- Closer to exiting learning phase = better performance

### When to Use Granular

Granular still makes sense when:
- Testing truly different audiences (US vs EU)
- Different products with different buyers
- Different offers requiring different messaging
- A/B testing specific variables

---

## Power 5 Framework

### What Is Power 5?

Meta's recommended framework from 2019-2022:
1. **Account Simplification** — Fewer campaigns
2. **Campaign Budget Optimization (CBO)** — Budget at campaign level
3. **Automatic Placements** — Let Meta choose
4. **Auto Advanced Matching** — Better tracking
5. **Dynamic Ads** — Personalized creative

### Is Power 5 Still Relevant in 2026?

**Yes and No.**

**Still Relevant:**
- Account simplification (more relevant than ever)
- Automatic placements (Advantage+ placements)
- Advanced matching (now standard with CAPI)
- Dynamic ads (evolved into Advantage+ Creative)

**Evolved:**
- CBO → Use contextually (not always)
- Dynamic ads → Advantage+ Shopping/Creative

### The Updated Framework

**Power 5 Version 2.0:**
1. **Consolidation** — Fewer campaigns, more budget per campaign
2. **Advantage+ Everything** — Placements, audience, creative
3. **Server-Side Tracking** — CAPI mandatory
4. **Creative Volume** — 5-10+ variations per ad set
5. **Broad Targeting** — Trust the algorithm

---

## Account Consolidation Benefits

### Why Consolidation Works

**1. Better Data Aggregation**
```
Fragmented: 10 ad sets × 5 conversions = Poor learning
Consolidated: 2 ad sets × 25 conversions = Good learning
```

**2. Faster Learning Phases**
- More conversions per ad set = faster exit from learning
- Stable performance sooner

**3. Lower CPMs**
- Less internal competition
- Algorithm has more flexibility
- Better auction efficiency

**4. Easier Management**
- Fewer things to monitor
- Clearer performance signals
- Less decision fatigue

### The Math of Consolidation

**Before Consolidation:**
| Campaign | Ad Sets | Daily Budget | Conversions/Week |
|----------|---------|--------------|------------------|
| Campaign 1 | 5 | $100 ($20 each) | ~23 total (~5 each) |
| Campaign 2 | 5 | $100 ($20 each) | ~23 total (~5 each) |
| Campaign 3 | 5 | $100 ($20 each) | ~23 total (~5 each) |
| **Total** | **15** | **$300** | **~70 (all learning limited)** |

**After Consolidation:**
| Campaign | Ad Sets | Daily Budget | Conversions/Week |
|----------|---------|--------------|------------------|
| Testing (ABO) | 3 | $100 ($33 each) | ~23 total (~8 each) |
| Scale (CBO) | 2 | $200 (CBO) | ~47 total (~24 each) |
| **Total** | **5** | **$300** | **~70 (better distributed)** |

Same budget, better learning distribution.

---

## When to Split vs Consolidate

### Split Into Separate Campaigns When:

**1. Different Objectives**
- Purchases vs Leads vs Traffic
- Each needs different optimization

**2. Different Funnels**
- Prospecting (cold traffic)
- Retargeting (warm traffic)
- These behave differently

**3. Different Products**
- Product A targets different buyer than Product B
- Different creative, different messaging

**4. Different Geographies**
- US vs International (different languages, cultures)
- Different pricing, different offers

**5. Testing vs Scaling**
- ABO for testing (control budget per creative)
- CBO for scaling (optimize among winners)

### Consolidate When:

**1. Same Objective**
- All going for purchases → Same campaign

**2. Similar Audiences**
- Multiple interest-based audiences → One broad audience

**3. Same Funnel Stage**
- All prospecting → Same campaign

**4. Overlapping Targeting**
- If audiences overlap >30%, consolidate

**5. Low Conversion Volume**
- If any ad set gets <50 conversions/week, consolidate

### The Overlap Problem

**Audience Overlap = Waste**

If Ad Set A and Ad Set B target overlapping users:
- Your ad sets compete against each other
- You bid against yourself
- CPMs increase unnecessarily

**Check Overlap:**
1. Go to Audiences in Ads Manager
2. Select 2+ audiences
3. Click ⋮ → "Show Audience Overlap"

**Rule:** If overlap >30%, consolidate or exclude.

---

## CBO vs ABO Deep Dive

### Campaign Budget Optimization (CBO)

**Definition:** Budget set at campaign level; Meta distributes across ad sets.

**How It Works:**
```
Campaign Budget: $300/day
    ↓
Meta evaluates ad sets
    ↓
Best performers get more budget
    ↓
Ad Set A: $180/day (winning)
Ad Set B: $90/day (ok)
Ad Set C: $30/day (struggling)
```

**Pros:**
- Automatic optimization
- Budget flows to winners
- Less manual management
- Better for scaling

**Cons:**
- Less control
- Some ad sets get starved
- Hard to test new creative
- Can't control learning pace

### Ad Set Budget Optimization (ABO)

**Definition:** Budget set at ad set level; each ad set gets its allocation.

**How It Works:**
```
Ad Set A: $100/day budget
Ad Set B: $100/day budget
Ad Set C: $100/day budget
    ↓
Each spends exactly $100
    ↓
You decide winners based on data
```

**Pros:**
- Full control
- Even distribution for testing
- Clear performance per creative
- Easier to identify winners

**Cons:**
- Manual management required
- May waste budget on losers
- Slower to scale winners
- More work

### When to Use Which

**Use ABO For:**
- Creative testing
- New campaign launches
- When you need learning on specific ad sets
- Testing specific audiences

**Use CBO For:**
- Scaling proven winners
- Retargeting campaigns
- When you have clear winners
- Reducing manual management

### The Two-Campaign System

**This is the optimal structure:**

```
Campaign 1: Creative Testing (ABO)
├── Ad Set: Angle A ($50/day)
├── Ad Set: Angle B ($50/day)
├── Ad Set: Angle C ($50/day)
└── Purpose: Find winners

Campaign 2: Scale (CBO)
├── Ad Set: Proven Winner 1
├── Ad Set: Proven Winner 2
├── Ad Set: Proven Winner 3
└── Purpose: Scale what works
```

**Workflow:**
1. Test new creative in ABO campaign
2. Identify winners (3+ days of good CPA)
3. Duplicate winners into CBO campaign
4. Scale CBO budget
5. Kill losers in ABO, add new tests
6. Repeat

---

## The 2026 Optimal Structure

### For Most Advertisers

```
AD ACCOUNT
│
├── Campaign 1: CREATIVE TESTING (ABO)
│   ├── Objective: Conversions (Purchases/Leads)
│   ├── Budget: Ad Set Level ($30-100 per ad set)
│   ├── Ad Set 1: Creative Angle A
│   │   └── 1-2 ads per angle
│   ├── Ad Set 2: Creative Angle B
│   │   └── 1-2 ads per angle
│   └── Ad Set 3: Creative Angle C
│       └── 1-2 ads per angle
│
├── Campaign 2: SCALE (CBO)
│   ├── Objective: Conversions (Purchases/Leads)
│   ├── Budget: Campaign Level (scale as needed)
│   ├── Ad Set 1: Proven Winner A (Broad)
│   │   └── 3-5 winning ads
│   ├── Ad Set 2: Proven Winner B (Broad)
│   │   └── 3-5 winning ads
│   └── Ad Set 3: Lookalike if needed
│       └── 3-5 winning ads
│
└── Campaign 3: RETARGETING (CBO or ABO)
    ├── Objective: Conversions
    ├── Budget: 15-25% of total spend
    ├── Ad Set 1: Website Visitors (7 days)
    │   └── 2-3 ads
    ├── Ad Set 2: Engagers (30 days)
    │   └── 2-3 ads
    └── Ad Set 3: Cart Abandoners (if applicable)
        └── 2-3 ads
```

### Budget Allocation

| Campaign | % of Budget | Purpose |
|----------|-------------|---------|
| Creative Testing (ABO) | 15-20% | Find new winners |
| Scale (CBO) | 60-70% | Drive results |
| Retargeting | 15-25% | Convert warm |

### Naming Convention

Use consistent naming for easy management:

```
[OBJECTIVE]_[TYPE]_[AUDIENCE]_[DATE]

Examples:
PURCH_TESTING_BROAD_2026-02
PURCH_SCALE_LAL1_2026-02
LEADS_RT_7DAY_2026-02
```

**Ad Set Naming:**
```
[AUDIENCE]_[ANGLE/CREATIVE]

Examples:
BROAD_PainPoint
LAL1%_Testimonial
RT7DAY_Offer
```

**Ad Naming:**
```
[FORMAT]_[HOOK/ANGLE]_[VERSION]

Examples:
VID_PainPoint_v1
IMG_Comparison_v2
CAR_Features_v1
```

### For Advantage+ Shopping Campaigns (Ecommerce)

When using ASC, structure changes:

```
AD ACCOUNT
│
├── Campaign 1: CREATIVE TESTING (ABO)
│   └── (Same as above)
│
├── Campaign 2: ASC (ADVANTAGE+ SHOPPING)
│   ├── Audience: Advantage+ (Auto)
│   ├── Existing Customer Budget: 0-20%
│   └── Ads: 5-10+ proven winners
│
└── Campaign 3: RETARGETING (Manual)
    └── For specific retargeting needs
```

**Note:** ASC combines prospecting and retargeting. You may not need a separate retargeting campaign.

---

## Common Structure Mistakes

### Mistake 1: Too Many Campaigns
**Problem:** 10+ campaigns with fragmented budget
**Fix:** Consolidate to 2-3 campaigns max

### Mistake 2: Too Many Ad Sets
**Problem:** 10+ ad sets per campaign, none learning
**Fix:** Maximum 3-5 ad sets per campaign

### Mistake 3: Using CBO for Testing
**Problem:** New creative gets no budget because existing winners dominate
**Fix:** Use ABO for testing, CBO for scaling

### Mistake 4: Mixing Objectives in One Campaign
**Problem:** Conversions and traffic in same campaign
**Fix:** One objective per campaign

### Mistake 5: No Retargeting Separation
**Problem:** Retargeting mixed with prospecting, hard to analyze
**Fix:** Separate retargeting campaign

### Mistake 6: Duplicate Audiences Competing
**Problem:** Same audience in multiple ad sets
**Fix:** Check overlap, consolidate or exclude

---

## Key Takeaways

1. **Simplify, don't complicate**
   - Fewer campaigns = better learning
   - Broad audiences beat detailed segmentation

2. **Two-campaign system works**
   - ABO for testing
   - CBO for scaling
   - Keep it simple

3. **Budget determines learning**
   - Each ad set needs 50+ conversions/week
   - Math first, then structure

4. **Consolidate overlapping audiences**
   - Check overlap regularly
   - You're bidding against yourself

5. **Naming conventions matter**
   - Consistent naming = easier management
   - Future you will thank present you

---

*Next: [Glossary](glossary.md)*

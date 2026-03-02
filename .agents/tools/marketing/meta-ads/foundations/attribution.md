# Attribution & Measurement

> What Meta reports and what actually happened can be very different. Understanding attribution is critical for making good decisions.

---

## Table of Contents
1. [Attribution Windows Explained](#attribution-windows-explained)
2. [View-Through vs Click-Through](#view-through-vs-click-through)
3. [What Meta Reports vs Reality](#what-meta-reports-vs-reality)
4. [Incrementality Testing](#incrementality-testing)
5. [Lift Studies](#lift-studies)
6. [Marketing Mix Modeling (MMM)](#marketing-mix-modeling-mmm)
7. [Third-Party Attribution Tools](#third-party-attribution-tools)
8. [How to Actually Measure Meta Impact](#how-to-actually-measure-meta-impact)

---

## Attribution Windows Explained

Attribution windows define how long after an ad interaction Meta will credit a conversion.

### Available Windows

| Window | What It Means | Best For |
|--------|---------------|----------|
| 1-day click | Conversion within 24h of click | Conservative measurement |
| 7-day click | Conversion within 7 days of click | Standard ecommerce |
| 1-day view | Conversion within 24h of view | Brand awareness |
| 7-day click, 1-day view | Both combined | Most campaigns |

### Default Setting

**2026 Default:** 7-day click, 1-day view

This means Meta will attribute a conversion if:
- User clicked your ad within the last 7 days, OR
- User viewed your ad within the last 1 day

### How to Choose

**7-day click, 1-day view (Standard):**
- Most ecommerce campaigns
- Products with 1-7 day consideration
- When you want full picture

**7-day click only:**
- Conservative measurement
- When view-through feels inflated
- B2B with longer cycles

**1-day click only:**
- Direct response campaigns
- Low-price impulse purchases
- When comparing to other platforms

**28-day click (requires API):**
- High-consideration purchases
- B2B with long sales cycles
- Enterprise software

### Setting Attribution Windows

**In Ads Manager:**
1. Campaign level → Edit
2. Attribution setting
3. Select window

**Note:** Changing attribution window doesn't change actual delivery — only reporting.

---

## View-Through vs Click-Through

### Click-Through Attribution

**Definition:** User clicked your ad, then converted.

**The Journey:**
```
User sees ad → Clicks ad → Lands on site → Converts
                  ↑
         Attributed to this click
```

**Strengths:**
- Clear intent signal
- User actively engaged
- Direct path to conversion

**Weaknesses:**
- Misses brand lift effect
- Ignores multiple touchpoints
- Undercounts display impact

### View-Through Attribution

**Definition:** User saw your ad (didn't click), then converted later.

**The Journey:**
```
User sees ad → Doesn't click → Later visits site directly → Converts
       ↑
   Attributed to this view
```

**Strengths:**
- Captures brand awareness effect
- Accounts for research behavior
- Reflects reality of ad influence

**Weaknesses:**
- Can feel inflated
- Hard to prove causation
- iOS users largely excluded (2024+)

### The Reality of View-Through

**Most purchases involve multiple touchpoints:**
1. User sees your ad (view, no click)
2. User sees it again (view, no click)
3. User researches product elsewhere
4. User returns and searches your brand
5. User converts via direct/organic

**Question:** Did the ads cause this, or would they have bought anyway?

### View-Through After iOS 14

**iOS Users:**
- ~80%+ opt out of tracking
- View-through largely unavailable for iOS
- Click-through still works (within limitations)

**What This Means:**
- View-through attribution increasingly represents Android/web users
- iOS conversion data is modeled, not directly tracked
- Total view-through conversions are underreported

---

## What Meta Reports vs Reality

### Meta's Incentive

Remember: Meta wants to take credit for conversions. Their attribution is designed to show Meta ads in the best light.

### Common Discrepancies

**Meta Reports More Than Reality:**
- Multiple platforms claim same conversion
- View-through may not be causal
- Post-iOS modeling can over-estimate
- Time zones can cause date mismatches

**Meta Reports Less Than Reality:**
- iOS users not tracked
- Ad blocker users not tracked
- Cross-device journeys missed
- Long purchase cycles exceed window

### The Multi-Touch Problem

**Example Journey:**
1. Day 1: User clicks Meta ad (Meta claims)
2. Day 2: User clicks Google ad (Google claims)
3. Day 3: User clicks TikTok ad (TikTok claims)
4. Day 4: User purchases

**Result:** 1 purchase, 3 platforms claiming credit

### Realistic Expectations

| What Meta Reports | What Likely Happened |
|-------------------|---------------------|
| 100 purchases | 70-90 actually from Meta |
| $50 CPA | $55-75 true CPA |
| 3x ROAS | 2-2.5x true ROAS |

**Rule of Thumb:** Discount Meta-reported conversions by 10-30% for realistic assessment.

---

## Incrementality Testing

The gold standard for measuring true ad impact.

### What Is Incrementality?

**Incremental conversions** = Conversions that would NOT have happened without the ad

**Formula:**
```
Incrementality = (Test Group Conversions - Control Group Conversions) / Test Group Conversions
```

### Running Incrementality Tests

**Method 1: Geo-Based Holdout**
1. Choose similar markets (e.g., Dallas vs Houston)
2. Run ads in one market only
3. Compare conversion rates
4. Difference = Incremental impact

**Method 2: Audience Holdout**
1. Split audience randomly (90% test, 10% control)
2. Show ads to test group only
3. Track conversions in both groups
4. Difference = Incremental lift

**Method 3: Platform Pause**
1. Pause all Meta ads for 2 weeks
2. Track total revenue/conversions
3. Compare to previous period
4. Revenue drop = Meta's incremental contribution

### Incrementality Benchmarks

| Campaign Type | Typical Incrementality |
|---------------|----------------------|
| Retargeting (hot) | 20-40% |
| Retargeting (warm) | 40-60% |
| Prospecting (lookalike) | 60-80% |
| Prospecting (broad) | 70-90% |

**Key Insight:** Retargeting has the lowest incrementality because many of those users would have purchased anyway. Prospecting drives more true net-new revenue.

### When to Run Incrementality Tests

- Before major budget increases
- Quarterly for ongoing campaigns
- When stakeholders question Meta ROI
- After significant strategy changes

---

## Lift Studies

Meta's official method for measuring incrementality.

### Types of Lift Studies

**Conversion Lift:**
- Measures additional conversions from ads
- Randomized control trial
- Most accurate for direct response

**Brand Lift:**
- Measures awareness, consideration, recall
- Survey-based
- Best for brand campaigns

### Running a Conversion Lift Study

**Requirements:**
- Minimum $30K spend during test
- 2-4 week test period
- Representative campaigns
- Clean measurement setup

**Process:**
1. Request through Meta rep or Experiments hub
2. Meta splits audience (test vs holdout)
3. Campaign runs normally
4. Meta compares conversion rates
5. Report shows incremental impact

### Interpreting Lift Study Results

**Key Metrics:**
- **Lift %:** How much higher conversions are in test vs control
- **Incremental Conversions:** Net new conversions caused by ads
- **Incremental ROAS:** Return on ad spend for net new revenue
- **Cost Per Incremental Conversion:** True CPA

**Example Results:**
```
Test Group Conversions: 1,000
Control Group Conversions: 400
Lift: 150%
Incremental Conversions: 600
Spend: $30,000
Cost Per Incremental Conversion: $50
```

### Limitations

- Expensive (requires significant spend)
- Time-consuming (weeks to run)
- Snapshot in time (may not reflect ongoing performance)
- Meta-conducted (potential bias)

---

## Marketing Mix Modeling (MMM)

Statistical analysis of how all marketing channels contribute to business outcomes.

### What Is MMM?

MMM uses regression analysis to determine how each marketing input (Meta, Google, TV, etc.) affects outputs (revenue, conversions).

### How MMM Works

**Inputs:**
- Spend by channel by week/month
- External factors (seasonality, economy, weather)
- Promotions and pricing
- Competitive activity

**Outputs:**
- Channel contribution to revenue
- Marginal ROI by channel
- Optimal budget allocation
- Diminishing returns curves

### MMM for Meta Ads

**Benefits:**
- No pixel/tracking required
- Works across all channels
- Accounts for offline impact
- Long-term view

**Limitations:**
- Requires 2+ years of data
- Expensive to build/maintain
- Results lag (historical analysis)
- Doesn't capture creative differences

### Robyn: Meta's Open Source MMM

Meta released **Robyn**, a free MMM tool:
- R-based statistical modeling
- Automated hyperparameter tuning
- Budget allocation recommendations
- Free to use

**Best For:**
- Companies spending $100K+/month
- Multi-channel marketing
- Long-term strategic planning

---

## Third-Party Attribution Tools

### Why Third-Party Tools?

Platform-reported data has inherent bias. Third-party tools provide:
- Unified view across channels
- Independent measurement
- Custom attribution models
- Better cross-device tracking

### Popular Tools

**Triple Whale** (Ecommerce Focus)
- First-party pixel tracking
- Post-purchase surveys
- Customer journey mapping
- Pricing: $129-$279/month

**Northbeam** (Multi-Touch)
- Machine learning attribution
- Incrementality modeling
- Cross-channel view
- Pricing: Custom ($500+/month)

**Rockerbox** (Enterprise)
- Multi-touch attribution
- Marketing mix modeling
- TV/offline integration
- Pricing: Enterprise only

**Dreamdata** (B2B Focus)
- B2B-specific attribution
- Account-based tracking
- Revenue attribution
- Pricing: $599-$999/month

**HockeyStack** (B2B/SaaS)
- Website + ad tracking
- Intent signals
- Account journeys
- Pricing: Custom

### What to Look For

| Feature | Importance | Why |
|---------|------------|-----|
| First-party tracking | Critical | Bypasses iOS/cookie issues |
| Survey integration | High | Direct customer feedback |
| CRM integration | High | Track to revenue |
| Cross-device | Medium | Connect user journeys |
| Incrementality | Medium | True impact measurement |

### Post-Purchase Surveys

The simplest form of attribution: ask customers.

**Question:** "How did you hear about us?"

**Options:**
- Facebook/Instagram
- Google
- TikTok
- Friend/family
- Podcast
- Other

**Benefits:**
- Zero-party data (customer provided)
- Works despite tracking limitations
- Captures word-of-mouth
- Simple to implement

**Limitations:**
- Memory bias (customers may not remember)
- First touch bias (ignores multi-touch)
- Response rates vary

---

## How to Actually Measure Meta Impact

### The Blended Approach

No single method is perfect. Use multiple:

```
1. Platform Reporting (Meta Ads Manager)
   └── Directional, inflated, but detailed

2. Third-Party Attribution
   └── More accurate, still imperfect

3. Post-Purchase Surveys
   └── Direct customer input

4. Incrementality Tests
   └── True causal impact

5. Business Metrics
   └── Did revenue actually increase?
```

### The MER Framework

**MER (Marketing Efficiency Ratio):**
```
MER = Total Revenue / Total Marketing Spend
```

Instead of obsessing over platform-specific ROAS, track business-wide efficiency.

**Example:**
- Total Revenue: $500,000
- Total Marketing Spend: $100,000
- MER: 5x

**Why MER Matters:**
- Accounts for all channels
- Reduces attribution arguments
- Focuses on business outcome
- Simple to track

### Blended CPA/ROAS

Track platform-reported AND blended metrics:

| Metric | What It Tells You |
|--------|-------------------|
| Meta-Reported ROAS | Platform-specific (inflated) |
| Blended ROAS | All marketing combined (realistic) |
| True ROAS | After incrementality adjustment |

**Example:**
```
Meta Reports:    3.5x ROAS
Blended:         2.8x ROAS
Incremental:     2.0x ROAS
```

### Monthly Attribution Review

Run this analysis monthly:

1. **Compare Sources:**
   - Meta-reported conversions
   - Third-party attributed conversions
   - Survey-attributed conversions
   - CRM-tracked conversions

2. **Calculate Discrepancy:**
   - How different are the sources?
   - Which is most conservative?

3. **Set Realistic Expectations:**
   - Use conservative number for planning
   - Use platform data for optimization

4. **Track Trends:**
   - Are discrepancies growing?
   - Is Meta reporting improving or declining?

### The "Reality Check" Test

**Every quarter, ask:**

1. If I turned off Meta ads completely, what would happen?
   - Run a holdout test or platform pause
   
2. Are new customers actually coming from Meta?
   - Survey data + CRM analysis

3. Is my business growing proportionally to Meta spend?
   - If 2x spend doesn't = ~2x growth, something's wrong

4. What do my best customers say?
   - Interview top customers on how they found you

---

## Attribution Settings Cheat Sheet

### For Ecommerce (1-7 Day Purchase Cycle)
- **Window:** 7-day click, 1-day view
- **Comparison:** Blended ROAS
- **Verification:** Triple Whale or similar

### For Lead Gen (7-30 Day Cycle)
- **Window:** 7-day click only
- **Comparison:** Lead-to-customer rate by source
- **Verification:** CRM tracking

### For B2B SaaS (30-180 Day Cycle)
- **Window:** 28-day click (via API)
- **Comparison:** Pipeline influence
- **Verification:** Dreamdata or HockeyStack

### For Brand Awareness
- **Window:** 1-day view
- **Comparison:** Brand lift study
- **Verification:** Survey data

---

## Key Takeaways

1. **Platform data is directional, not gospel**
   - Meta wants credit for conversions
   - Use for optimization, not truth

2. **Click-through > View-through for conservative measurement**
   - View-through is partially inflated
   - iOS changes make it less reliable

3. **Incrementality is the gold standard**
   - Measures true causal impact
   - Run tests quarterly

4. **Use multiple measurement methods**
   - No single source is perfect
   - Cross-reference everything

5. **Focus on business outcomes**
   - MER and blended metrics matter more
   - Did the business actually grow?

---

*Next: [Account Structure Philosophy](account-structure.md)*

# Metrics Explained

> Every metric you'll see in Ads Manager, what it means, and benchmarks.

---

## Primary Metrics by Objective

### For Purchase/Sales Campaigns

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **ROAS** | Revenue ÷ Spend | 2-3x | 4x+ |
| **CPA** | Spend ÷ Purchases | Industry avg | Below avg |
| **Purchase Value** | Total revenue | Growing | Target met |
| **AOV** | Revenue ÷ Orders | Stable+ | Increasing |

### For Lead Generation

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **CPL** | Spend ÷ Leads | <$50 | <$25 |
| **Cost per Demo** | Spend ÷ Demos | <$150 | <$80 |
| **Lead-to-SQL %** | SQLs ÷ Leads × 100 | 20%+ | 35%+ |

### For App Installs

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **CPI** | Spend ÷ Installs | Category avg | Below avg |
| **Install Rate** | Installs ÷ Clicks | 5%+ | 10%+ |

### For Awareness

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Reach** | Unique people | Target met | Exceeded |
| **CPM** | Cost per 1000 impressions | <$15 | <$8 |
| **Ad Recall Lift** | Estimated memory | Growing | Target met |

---

## Engagement Metrics

### Click Metrics

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **CTR (All)** | All Clicks ÷ Impressions | 1%+ | 2%+ |
| **CTR (Link)** | Link Clicks ÷ Impressions | 0.8%+ | 1.5%+ |
| **CPC (All)** | Spend ÷ All Clicks | <$1 | <$0.50 |
| **CPC (Link)** | Spend ÷ Link Clicks | <$2 | <$1 |
| **Outbound CTR** | Outbound Clicks ÷ Impressions | 0.5%+ | 1%+ |

### Video Metrics

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Hook Rate** | 3s Views ÷ Impressions | 30%+ | 45%+ |
| **Hold Rate** | 15s Views ÷ 3s Views | 30%+ | 50%+ |
| **ThruPlay Rate** | ThruPlays ÷ Impressions | 10%+ | 20%+ |
| **Avg Watch Time** | Total Watch Time ÷ Views | 5s+ | 10s+ |
| **CPV (ThruPlay)** | Spend ÷ ThruPlays | <$0.05 | <$0.02 |

### Landing Page Metrics

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Landing Page Views** | Confirmed page loads | Close to clicks | = Clicks |
| **LPV vs Clicks Gap** | LPV ÷ Clicks | 80%+ | 95%+ |
| **Bounce Rate** | Single page visits | <70% | <50% |
| **Conversion Rate** | Conversions ÷ LPV | 5%+ | 15%+ |

---

## Cost Metrics

### CPM (Cost Per 1000 Impressions)

**What Affects CPM:**
- Audience size (smaller = higher)
- Competition (more = higher)
- Ad quality (lower = higher)
- Time of year (Q4 = higher)
- Placement (Feed > Audience Network)

**Typical CPMs by Industry:**
| Industry | Average CPM |
|----------|------------|
| E-commerce | $10-15 |
| SaaS/B2B | $15-25 |
| Finance | $20-30 |
| Gaming | $8-12 |

### CPC (Cost Per Click)

**Formula:**
```
CPC = Spend ÷ Clicks
    = CPM ÷ (CTR × 10)
```

**Lower CPC Through:**
- Higher CTR (more clicks per impression)
- Lower CPM (cheaper impressions)
- Better ad relevance

### CPA (Cost Per Action)

**Formula:**
```
CPA = Spend ÷ Actions
    = CPC ÷ Conversion Rate
```

**Lower CPA Through:**
- Lower CPC
- Higher conversion rate
- Better landing page
- Better offer

---

## Quality Metrics

### Ad Relevance Diagnostics

Meta rates your ad on three dimensions:

| Ranking | Meaning |
|---------|---------|
| Above Average | Top 35-55% |
| Average | Middle 35-55% |
| Below Average (Bottom 35%) | Warning zone |
| Below Average (Bottom 20%) | Fix immediately |
| Below Average (Bottom 10%) | Serious issue |

**Quality Ranking:**
How your ad's perceived quality compares to competitors.

**Engagement Rate Ranking:**
Expected engagement compared to competitors.

**Conversion Rate Ranking:**
Expected conversion rate compared to competitors.

### Frequency

**Formula:**
```
Frequency = Impressions ÷ Reach
```

**Frequency Guidelines:**
| Campaign Type | Warning | Action Needed |
|---------------|---------|---------------|
| Prospecting | 2.5+ | 3.5+ |
| Retargeting | 4.0+ | 6.0+ |
| Brand Awareness | 3.0+ | 5.0+ |

**High Frequency Signs:**
- CTR declining
- CPA increasing
- Negative feedback increasing
- Same audience seeing ad repeatedly

---

## Conversion Metrics

### Conversion Rate

**Formula:**
```
CVR = Conversions ÷ Clicks × 100
```

**Or:**
```
CVR = Conversions ÷ Landing Page Views × 100
```

**Benchmarks:**
| Industry | Good CVR | Great CVR |
|----------|----------|-----------|
| E-commerce | 2-4% | 5%+ |
| Lead Gen | 10-15% | 20%+ |
| SaaS Trial | 5-10% | 15%+ |

### ROAS (Return on Ad Spend)

**Formula:**
```
ROAS = Revenue ÷ Ad Spend
```

**Example:**
- Ad Spend: $1,000
- Revenue: $4,000
- ROAS: 4x (or 400%)

**Breakeven ROAS:**
```
Breakeven ROAS = 1 ÷ Profit Margin
```

**Example:**
- Profit Margin: 30%
- Breakeven ROAS: 1 ÷ 0.30 = 3.33x

### MER (Marketing Efficiency Ratio)

**Formula:**
```
MER = Total Revenue ÷ Total Marketing Spend
```

**Why MER > ROAS:**
- Accounts for all channels
- Reduces attribution arguments
- Business-level view

---

## Custom Metrics to Create

### In Ads Manager

**Click to LPV Ratio:**
```
Landing Page Views ÷ Link Clicks × 100
Purpose: Identify page load issues
```

**Hook Rate:**
```
3-Second Video Views ÷ Impressions × 100
Purpose: Measure hook effectiveness
```

**Hold Rate:**
```
ThruPlays ÷ 3-Second Video Views × 100
Purpose: Measure content engagement
```

### In Spreadsheet

**True CPA (Adjusted for Quality):**
```
Ad Spend ÷ Qualified Conversions
Purpose: Real cost of quality conversions
```

**Blended ROAS:**
```
Total Revenue ÷ Total Ad Spend (all platforms)
Purpose: True return across channels
```

**Contribution Margin:**
```
(Revenue - COGS - Ad Spend) ÷ Revenue × 100
Purpose: True profitability
```

---

## Reading Metrics Together

### Diagnostic Combos

| High | Low | Likely Issue |
|------|-----|--------------|
| CPM | CTR | Creative not compelling |
| CTR | CVR | Landing page problem |
| CPM | — | Competition or quality |
| Frequency | CTR | Ad fatigue |
| LPV Gap | — | Page load issues |

### Performance Patterns

**Healthy Campaign:**
```
CPM: Stable
CTR: 1%+
CVR: Meeting target
CPA: At or below target
Frequency: <3
```

**Fatiguing Campaign:**
```
CPM: Rising or stable
CTR: Declining
Frequency: Rising (>3)
CPA: Rising
Action: Refresh creative
```

**Quality Issue:**
```
CPM: High or rising
CTR: Low
Quality Ranking: Below Average
Action: Improve creative/targeting
```

---

## Metric Review Cadence

### Daily
- Spend (on budget?)
- CPA/ROAS (meeting targets?)
- Any delivery issues?

### Weekly
- CTR trend
- Frequency
- Creative performance
- Audience performance

### Monthly
- Overall ROAS/CPA vs target
- Attribution review
- Creative refresh needs
- Budget allocation review

---

## Advanced Metrics Analysis

### Cohort Analysis

Track how different acquisition cohorts perform over time:

**Monthly Cohort Example:**
| Cohort | Month 1 Revenue | Month 3 Revenue | LTV at 6 Months |
|--------|-----------------|-----------------|-----------------|
| Jan Acquired | $100 | $180 | $320 |
| Feb Acquired | $95 | $165 | $290 |
| Mar Acquired | $110 | $195 | $350 |

**What This Tells You:**
- Which campaigns bring higher-value customers
- If recent acquisitions are improving or declining
- True ROI of campaigns over time

### Incrementality-Adjusted Metrics

**Raw ROAS vs Incremental ROAS:**
```
Raw ROAS: 3.0x (what Meta reports)
Incrementality: 60% (from lift study)
Incremental ROAS: 3.0 × 0.6 = 1.8x (true value)
```

**When to Use:**
- Budget allocation decisions
- Channel comparison
- True ROI reporting

### Contribution Margin Analysis

**Formula:**
```
Contribution Margin = Revenue - COGS - Ad Spend - Variable Costs
CM% = Contribution Margin / Revenue × 100
```

**Example:**
```
Revenue: $10,000
COGS: $4,000
Ad Spend: $2,500
Shipping/Variable: $500
Contribution Margin: $3,000
CM%: 30%
```

### Break-Even Calculations

**Break-Even ROAS:**
```
Break-Even ROAS = 1 / Gross Margin %

Example:
Gross Margin: 60%
Break-Even ROAS: 1 / 0.60 = 1.67x
```

**Break-Even CPA:**
```
Break-Even CPA = Average Order Value × Gross Margin %

Example:
AOV: $80
Gross Margin: 60%
Break-Even CPA: $80 × 0.60 = $48
```

---

## Custom Columns Setup

### Recommended Custom Columns

Create these in Ads Manager → Columns → Customize Columns:

**For Ecommerce:**
1. ROAS (Purchase)
2. Cost Per Purchase
3. Purchase Conversion Value
4. Website Purchases
5. CTR (Link Click)
6. CPM
7. Frequency
8. Reach

**For Lead Gen:**
1. Cost Per Lead
2. Leads
3. Lead Conversion Rate
4. CTR (Link Click)
5. Landing Page Views
6. CPM
7. Frequency
8. Quality Ranking

**For Video:**
1. ThruPlay Cost
2. ThruPlays
3. 3-Second Video Views
4. Video Average Watch Time
5. CTR (All)
6. CPM
7. Reach
8. Frequency

### Calculated Metrics to Add

**Hook Rate:**
```
3-Second Video Views / Impressions × 100
```

**Landing Page View Rate:**
```
Landing Page Views / Link Clicks × 100
```

**Cost Per Landing Page View:**
```
Amount Spent / Landing Page Views
```

---

## Reporting Templates

### Daily Report (5 min)
```
Date: ___________

Spend: $_______ (vs plan: $_______)
Results: _______ (vs plan: _______)
CPA: $_______ (vs target: $_______)

Issues: ________________________

Action: ________________________
```

### Weekly Report
```
Week: ___________

Performance vs Target:
| Metric | Target | Actual | Variance |
|--------|--------|--------|----------|
| Spend | | | |
| Results | | | |
| CPA | | | |
| ROAS | | | |

Top Performers:
1. [Ad/Ad Set] — [Metric]
2. [Ad/Ad Set] — [Metric]

Underperformers:
1. [Ad/Ad Set] — [Metric]
2. [Ad/Ad Set] — [Metric]

Actions Taken:
- 
-

Next Week Plan:
-
-
```

---

*Next: [Scaling Playbook](scaling.md)*

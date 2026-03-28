# Metrics Explained

> Every metric in Ads Manager — definitions, formulas, and benchmarks.

## Primary Metrics by Objective

### Purchase/Sales

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **ROAS** | Revenue ÷ Spend | 2-3x | 4x+ |
| **CPA** | Spend ÷ Purchases | Industry avg | Below avg |
| **Purchase Value** | Total revenue | Growing | Target met |
| **AOV** | Revenue ÷ Orders | Stable+ | Increasing |

### Lead Generation

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **CPL** | Spend ÷ Leads | <$50 | <$25 |
| **Cost per Demo** | Spend ÷ Demos | <$150 | <$80 |
| **Lead-to-SQL %** | SQLs ÷ Leads × 100 | 20%+ | 35%+ |

### App Installs

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **CPI** | Spend ÷ Installs | Category avg | Below avg |
| **Install Rate** | Installs ÷ Clicks | 5%+ | 10%+ |

### Awareness

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Reach** | Unique people | Target met | Exceeded |
| **CPM** | Cost per 1000 impressions | <$15 | <$8 |
| **Ad Recall Lift** | Estimated memory | Growing | Target met |

## Engagement Metrics

### Clicks

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **CTR (All)** | All Clicks ÷ Impressions | 1%+ | 2%+ |
| **CTR (Link)** | Link Clicks ÷ Impressions | 0.8%+ | 1.5%+ |
| **CPC (All)** | Spend ÷ All Clicks | <$1 | <$0.50 |
| **CPC (Link)** | Spend ÷ Link Clicks | <$2 | <$1 |
| **Outbound CTR** | Outbound Clicks ÷ Impressions | 0.5%+ | 1%+ |

### Video

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Hook Rate** | 3s Views ÷ Impressions | 30%+ | 45%+ |
| **Hold Rate** | 15s Views ÷ 3s Views | 30%+ | 50%+ |
| **ThruPlay Rate** | ThruPlays ÷ Impressions | 10%+ | 20%+ |
| **Avg Watch Time** | Total Watch Time ÷ Views | 5s+ | 10s+ |
| **CPV (ThruPlay)** | Spend ÷ ThruPlays | <$0.05 | <$0.02 |

### Landing Page

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Landing Page Views** | Confirmed page loads | Close to clicks | = Clicks |
| **LPV vs Clicks Gap** | LPV ÷ Clicks | 80%+ | 95%+ |
| **Bounce Rate** | Single page visits | <70% | <50% |
| **Conversion Rate** | Conversions ÷ LPV | 5%+ | 15%+ |

## Cost Metrics Deep Dive

### CPM Factors

- Audience size (smaller = higher), competition (more = higher), ad quality (lower = higher)
- Seasonality (Q4 = higher), placement (Feed > Audience Network)

| Industry | Average CPM |
|----------|------------|
| E-commerce | $10-15 |
| SaaS/B2B | $15-25 |
| Finance | $20-30 |
| Gaming | $8-12 |

### CPC & CPA Formulas

```
CPC = Spend ÷ Clicks = CPM ÷ (CTR × 10)
CPA = Spend ÷ Actions = CPC ÷ Conversion Rate
```

**Lower CPC through:** higher CTR, lower CPM, better ad relevance.
**Lower CPA through:** lower CPC, higher conversion rate, better landing page/offer.

## Quality Metrics

### Ad Relevance Diagnostics

Meta rates ads on three dimensions — **Quality Ranking**, **Engagement Rate Ranking**, **Conversion Rate Ranking** — each compared to competitors:

| Ranking | Meaning |
|---------|---------|
| Above Average | Top 35-55% |
| Average | Middle 35-55% |
| Below Average (Bottom 35%) | Warning zone |
| Below Average (Bottom 20%) | Fix immediately |
| Below Average (Bottom 10%) | Serious issue |

### Frequency

```
Frequency = Impressions ÷ Reach
```

| Campaign Type | Warning | Action Needed |
|---------------|---------|---------------|
| Prospecting | 2.5+ | 3.5+ |
| Retargeting | 4.0+ | 6.0+ |
| Brand Awareness | 3.0+ | 5.0+ |

**High frequency signs:** CTR declining, CPA increasing, negative feedback increasing, same audience seeing ad repeatedly.

## Conversion & Revenue Metrics

### Conversion Rate

```
CVR = Conversions ÷ Landing Page Views × 100
```

| Industry | Good CVR | Great CVR |
|----------|----------|-----------|
| E-commerce | 2-4% | 5%+ |
| Lead Gen | 10-15% | 20%+ |
| SaaS Trial | 5-10% | 15%+ |

### ROAS & Break-Even

```
ROAS = Revenue ÷ Ad Spend
Breakeven ROAS = 1 ÷ Profit Margin   (e.g. 30% margin → 3.33x)
Breakeven CPA  = AOV × Gross Margin % (e.g. $80 AOV × 60% → $48)
```

**Example:** $1,000 spend, $4,000 revenue → ROAS 4x (400%).

### MER (Marketing Efficiency Ratio)

```
MER = Total Revenue ÷ Total Marketing Spend
```

Advantages over ROAS: accounts for all channels, reduces attribution arguments, provides business-level view.

### Contribution Margin

```
Contribution Margin = Revenue - COGS - Ad Spend - Variable Costs
CM% = Contribution Margin / Revenue × 100
```

### Incrementality-Adjusted Metrics

```
Incremental ROAS = Raw ROAS × Incrementality %
Example: 3.0x × 60% lift = 1.8x true value
```

Use for budget allocation, channel comparison, and true ROI reporting.

## Custom Metrics to Create

### In Ads Manager

| Metric | Formula | Purpose |
|--------|---------|---------|
| Click to LPV Ratio | Landing Page Views ÷ Link Clicks × 100 | Identify page load issues |
| Hook Rate | 3-Second Video Views ÷ Impressions × 100 | Measure hook effectiveness |
| Hold Rate | ThruPlays ÷ 3-Second Video Views × 100 | Measure content engagement |
| Cost Per LPV | Amount Spent ÷ Landing Page Views | Landing page cost efficiency |

### In Spreadsheet

| Metric | Formula | Purpose |
|--------|---------|---------|
| True CPA | Ad Spend ÷ Qualified Conversions | Real cost of quality conversions |
| Blended ROAS | Total Revenue ÷ Total Ad Spend (all platforms) | True return across channels |

## Diagnostic Combos

| High | Low | Likely Issue |
|------|-----|--------------|
| CPM | CTR | Creative not compelling |
| CTR | CVR | Landing page problem |
| CPM | — | Competition or quality |
| Frequency | CTR | Ad fatigue |
| LPV Gap | — | Page load issues |

### Performance Patterns

| Pattern | CPM | CTR | Frequency | CPA | Action |
|---------|-----|-----|-----------|-----|--------|
| **Healthy** | Stable | 1%+ | <3 | At/below target | Maintain |
| **Fatiguing** | Rising/stable | Declining | Rising (>3) | Rising | Refresh creative |
| **Quality issue** | High/rising | Low | — | — | Improve creative/targeting |

## Metric Review Cadence

- **Daily:** Spend (on budget?), CPA/ROAS (meeting targets?), delivery issues
- **Weekly:** CTR trend, frequency, creative performance, audience performance
- **Monthly:** Overall ROAS/CPA vs target, attribution review, creative refresh needs, budget allocation

## Cohort Analysis

Track acquisition cohort performance over time:

| Cohort | Month 1 Revenue | Month 3 Revenue | LTV at 6 Months |
|--------|-----------------|-----------------|-----------------|
| Jan Acquired | $100 | $180 | $320 |
| Feb Acquired | $95 | $165 | $290 |
| Mar Acquired | $110 | $195 | $350 |

## Recommended Custom Columns

Create in Ads Manager → Columns → Customize Columns:

- **Ecommerce:** ROAS, Cost Per Purchase, Purchase Conversion Value, Website Purchases, CTR (Link Click), CPM, Frequency, Reach
- **Lead Gen:** Cost Per Lead, Leads, Lead Conversion Rate, CTR (Link Click), Landing Page Views, CPM, Frequency, Quality Ranking
- **Video:** ThruPlay Cost, ThruPlays, 3-Second Video Views, Video Average Watch Time, CTR (All), CPM, Reach, Frequency

---

*Next: [Scaling Playbook](scaling.md)*

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
| **Hold Rate** | ThruPlays ÷ 3s Views | 30%+ | 50%+ |
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

## Cost Metrics

### CPM Factors

Audience size (smaller = higher), competition (more = higher), ad quality (lower = higher), seasonality (Q4 = higher), placement (Feed > Audience Network).

| Industry | Average CPM |
|----------|------------|
| E-commerce | $10-15 |
| SaaS/B2B | $15-25 |
| Finance | $20-30 |
| Gaming | $8-12 |

### CPC & CPA

```
CPC = Spend ÷ Clicks = CPM ÷ (CTR × 10)
CPA = Spend ÷ Actions = CPC ÷ Conversion Rate
```

**Lower CPC:** higher CTR, lower CPM, better ad relevance. **Lower CPA:** lower CPC, higher CVR, better LP/offer.

## Quality Metrics

### Ad Relevance Diagnostics

Meta rates ads on **Quality Ranking**, **Engagement Rate Ranking**, and **Conversion Rate Ranking** vs competitors:

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

**High frequency signs:** CTR declining, CPA increasing, negative feedback increasing.

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

| Metric | Formula | Where | Purpose |
|--------|---------|-------|---------|
| Click to LPV Ratio | Landing Page Views ÷ Link Clicks × 100 | Ads Manager | Identify page load issues |
| Cost Per LPV | Amount Spent ÷ Landing Page Views | Ads Manager | Landing page cost efficiency |
| True CPA | Ad Spend ÷ Qualified Conversions | Spreadsheet | Real cost of quality conversions |
| Blended ROAS | Total Revenue ÷ Total Ad Spend (all platforms) | Spreadsheet | True return across channels |

## Diagnostic Patterns

| Pattern | CPM | CTR | Frequency | CPA | Action |
|---------|-----|-----|-----------|-----|--------|
| **Healthy** | Stable | 1%+ | <3 | At/below target | Maintain |
| **Fatiguing** | Rising | Declining | >3 | Rising | Refresh creative |
| **Quality issue** | High | Low | — | — | Improve creative/targeting |
| **LP problem** | Normal | Good | — | High | Fix landing page |
| **Audience exhausted** | Rising | Declining | High | Rising | Expand audience |

## Metric Review Cadence

- **Daily:** Spend (on budget?), CPA/ROAS (meeting targets?), delivery issues
- **Weekly:** CTR trend, frequency, creative performance, audience performance
- **Monthly:** Overall ROAS/CPA vs target, attribution review, creative refresh needs, budget allocation

## Recommended Custom Columns (Ads Manager → Columns → Customize Columns)

- **Ecommerce:** ROAS, Cost Per Purchase, Purchase Conversion Value, Website Purchases, CTR (Link Click), CPM, Frequency, Reach
- **Lead Gen:** Cost Per Lead, Leads, Lead Conversion Rate, CTR (Link Click), Landing Page Views, CPM, Frequency, Quality Ranking
- **Video:** ThruPlay Cost, ThruPlays, 3-Second Video Views, Video Average Watch Time, CTR (All), CPM, Reach, Frequency

---

*Next: [Scaling Playbook](scaling.md)*

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

## Click Metrics

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **CTR (All)** | All Clicks ÷ Impressions | 1%+ | 2%+ |
| **CTR (Link)** | Link Clicks ÷ Impressions | 0.8%+ | 1.5%+ |
| **CPC (All)** | Spend ÷ All Clicks | <$1 | <$0.50 |
| **CPC (Link)** | Spend ÷ Link Clicks | <$2 | <$1 |
| **Outbound CTR** | Outbound Clicks ÷ Impressions | 0.5%+ | 1%+ |

## Video Metrics

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Hook Rate** | 3s Views ÷ Impressions | 30%+ | 45%+ |
| **Hold Rate** | ThruPlays ÷ 3s Views | 30%+ | 50%+ |
| **ThruPlay Rate** | ThruPlays ÷ Impressions | 10%+ | 20%+ |
| **Avg Watch Time** | Total Watch Time ÷ Views | 5s+ | 10s+ |
| **CPV (ThruPlay)** | Spend ÷ ThruPlays | <$0.05 | <$0.02 |

## Landing Page Metrics

| Metric | Definition | Good | Great |
|--------|------------|------|-------|
| **Landing Page Views** | Confirmed page loads | Close to clicks | = Clicks |
| **LPV vs Clicks Gap** | LPV ÷ Clicks | 80%+ | 95%+ |
| **Bounce Rate** | Single page visits | <70% | <50% |
| **LP Conversion Rate** | Conversions ÷ LPV | 5%+ | 15%+ |

## Cost Metrics

**CPM factors:** smaller audience, more competition, lower ad quality, Q4 seasonality, premium placements (Feed > Audience Network).

| Industry | Average CPM |
|----------|------------|
| E-commerce | $10-15 |
| SaaS/B2B | $15-25 |
| Finance | $20-30 |
| Gaming | $8-12 |

```text
CPC = Spend ÷ Clicks = CPM ÷ (CTR × 10)    ← lower via: higher CTR, lower CPM, better relevance
CPA = Spend ÷ Actions = CPC ÷ Conversion Rate ← lower via: lower CPC, higher CVR, better LP/offer
```

## Quality Metrics

### Ad Relevance Diagnostics

Applies to Quality, Engagement Rate, and Conversion Rate rankings:

| Ranking | Meaning |
|---------|---------|
| Above Average | Top 35-55% |
| Average | Middle 35-55% |
| Below Average (Bottom 35%) | Warning zone |
| Below Average (Bottom 20%) | Fix immediately |
| Below Average (Bottom 10%) | Serious issue |

### Frequency

```text
Frequency = Impressions ÷ Reach
```

| Campaign Type | Warning | Action Needed |
|---------------|---------|---------------|
| Prospecting | 2.5+ | 3.5+ |
| Retargeting | 4.0+ | 6.0+ |
| Brand Awareness | 3.0+ | 5.0+ |

High frequency signals: declining CTR, rising CPA, increasing negative feedback.

## Conversion & Revenue Metrics

| Industry | Good CVR | Great CVR |
|----------|----------|-----------|
| E-commerce | 2-4% | 5%+ |
| Lead Gen | 10-15% | 20%+ |
| SaaS Trial | 5-10% | 15%+ |

```text
CVR             = Conversions ÷ Landing Page Views × 100
ROAS            = Revenue ÷ Ad Spend
Breakeven ROAS  = 1 ÷ Profit Margin                      (e.g. 30% margin → 3.33x)
Breakeven CPA   = AOV × Gross Margin %                    (e.g. $80 AOV × 60% → $48)
MER             = Total Revenue ÷ Total Marketing Spend   (cross-channel; better than ROAS for attribution)
CM              = Revenue - COGS - Ad Spend - Variable Costs
CM%             = CM / Revenue × 100
Incremental ROAS = Raw ROAS × Incrementality %            (e.g. 3.0x × 60% lift = 1.8x true value)
```

Use MER for cross-channel budget allocation. Use Incremental ROAS for true ROI reporting.

## Custom Metrics to Create

| Metric | Formula | Purpose |
|--------|---------|---------|
| Click to LPV Ratio | LPV ÷ Link Clicks × 100 | Detect page load issues |
| Cost Per LPV | Spend ÷ LPV | LP cost efficiency |
| True CPA | Spend ÷ Qualified Conversions | Quality conversion cost |
| Blended ROAS | Total Revenue ÷ Total Ad Spend (all platforms) | Cross-channel return |

## Diagnostic Patterns

| Pattern | CPM | CTR | Frequency | CPA | Action |
|---------|-----|-----|-----------|-----|--------|
| **Healthy** | Stable | 1%+ | <3 | At/below target | Maintain |
| **Fatiguing** | Rising | Declining | >3 | Rising | Refresh creative |
| **Quality issue** | High | Low | — | — | Improve creative/targeting |
| **LP problem** | Normal | Good | — | High | Fix landing page |
| **Audience exhausted** | Rising | Declining | High | Rising | Expand audience |

## Review Cadence

- **Daily:** Spend, CPA/ROAS, delivery issues
- **Weekly:** CTR trend, frequency, creative performance, audience performance
- **Monthly:** Overall ROAS/CPA vs target, attribution review, creative refresh needs, budget allocation

## Recommended Custom Columns

Set via Ads Manager → Columns → Customize Columns.

| Objective | Columns |
|-----------|---------|
| **Ecommerce** | ROAS, Cost Per Purchase, Purchase Conversion Value, Website Purchases, CTR (Link Click), CPM, Frequency, Reach |
| **Lead Gen** | Cost Per Lead, Leads, Lead Conversion Rate, CTR (Link Click), Landing Page Views, CPM, Frequency, Quality Ranking |
| **Video** | ThruPlay Cost, ThruPlays, 3-Second Video Views, Video Average Watch Time, CTR (All), CPM, Reach, Frequency |

---

*Next: [Scaling Playbook](meta-ads-optimization-scaling.md)*

# Targeting Strategies

> In 2026, targeting is less about finding people and more about giving Meta's AI the right signals.

## Targeting Hierarchy (Most → Least Effective)

1. **Broad + Great Creative** — Let AI find buyers
2. **Lookalike (1-3%)** — Similar to best customers
3. **Custom Audiences** — Your first-party data
4. **Interest/Behavior Layering** — Manual targeting
5. **Detailed Interest Only** — Most restricted

## Broad Targeting

Minimal restrictions — let Meta's algorithm find buyers.

```text
Location: [Your target countries]
Age: 18-65+ (or product minimum)
Gender: All
Detailed Targeting: None
Advantage+ Audience: ON
```

Meta's algorithm has billions of data points, real-time cross-placement optimization, cross-advertiser insights, and learns from your conversion data. Manual targeting relies on static hypotheses with limited data. Broad + good creative often beats detailed targeting.

| Broad Works When | Broad Fails When |
|------------------|------------------|
| 50+ conversions/week | Brand new account (no data) |
| Creative clearly signals audience | Very niche B2B product |
| Scaling phase | Compliance/legal restrictions |
| Algorithm has conversion history | Very small TAM |

## Lookalike Audiences

### Source Quality

| Source Audience | Quality |
|-----------------|---------|
| Closed-won customers (high LTV) | Best |
| All paying customers | Great |
| Sales-qualified leads | Good |
| Marketing-qualified leads | OK |
| All leads / Website visitors | Fair |
| Engagers | Poor |

### Building Lookalikes

```text
1. Prepare source: Top 500-1000 customers by LTV (email, phone, name, country as CSV)
2. Audiences → Create Audience → Custom Audience → Customer List → Upload
   Name: "Customers - High LTV - 2026"
3. Audiences → Create Audience → Lookalike → Source: your custom audience
   Location: target country | Size: 1% to start
```

### Lookalike Percentages

| % | Audience Size (US) | Quality |
|---|-------------------|---------|
| 1% | ~2.3M | Highest |
| 2% | ~4.6M | High |
| 3% | ~6.9M | Good |
| 5% | ~11.5M | Medium |
| 10% | ~23M | Lower |

Start at 1%, expand when you need reach.

### Stacked Lookalikes

Test different sources in separate ad sets — let them compete:

```text
Ad Set 1: LAL 1% - Customers (High LTV)
Ad Set 2: LAL 1% - All Customers
Ad Set 3: LAL 1% - Demo Completers
```

**Lookalikes beat broad when:** limited conversion history, very specific customer profile, high-quality unique source audience, or broad isn't performing.

## Interest & Behavior Targeting

### B2B Interest Layering

```text
Example for Marketing SaaS:
Interest: HubSpot OR Salesforce OR Marketo
AND Interest: Digital Marketing OR Content Marketing
AND Behavior: Small Business Owners
```

### B2C Interest Selection

Start with competitor brands, related products, lifestyle indicators, media consumed.

```text
Example for Fitness Product:
Interest: CrossFit OR Orange Theory OR Peloton
AND Interest: Health & Wellness
```

### Interest Research

1. **Audience Insights** (Ads Manager) — check converter interests, find adjacent ones
2. **Facebook Ad Library** — see competitor targeting patterns
3. **Customer Surveys** — brands they follow, publications they read
4. **Competitor Lookalike** — target interest in competitor brand

### Behavior Targeting

| Behavior | Good For |
|----------|----------|
| Small Business Owners | B2B SMB |
| Business Page Admins | B2B, agency services |
| Technology Early Adopters | SaaS, tech products |
| Online Shoppers | Ecommerce |
| Frequent Travelers | Travel, luxury |

## First-Party Data Strategy

### Upload Data Types

| Data Type | Match Rate | Notes |
|-----------|------------|-------|
| Email | 50-70% | Primary identifier |
| Phone | 30-50% | Secondary identifier |
| First/Last Name | Improves match | Always include |
| City/State/Country | Improves match | Country required |

### Segmentation

| Dimension | Segments |
|-----------|----------|
| Value | High LTV (top 20%), all customers, high-spenders (by AOV) |
| Behavior | Recent purchasers (90d), repeat (2+ orders), lapsed (6+ months) |
| Stage | Leads not yet customers, trial users, churned customers |

### High-Intent Website Audiences

```text
Pricing Page Visitors (7 days)    Demo Page Visitors (14 days)
Add to Cart (14 days)             Checkout Started (7 days)
```

### Engagement Audiences

```text
Video Views 50%+ (30 days)    Video Views 95% (60 days)
Page Engagers (90 days)       Ad Engagers (30 days)
```

## Exclusion Strategy

**Always exclude from prospecting:** recent purchasers (7-30 days), current customers (CRM list), employees.
**Exclude from retargeting:** already converted on this offer, higher-intent audiences (in lower-intent campaigns).

```text
Ad Set → Audience → Exclude People → Custom Audiences → Select audience
```

### Exclusion Waterfall (Retargeting)

```text
Campaign: Retargeting
├── Ad Set: Cart Abandoners
│   └── Exclude: Purchasers
├── Ad Set: Product Viewers
│   └── Exclude: Purchasers, Cart Abandoners
└── Ad Set: All Visitors
    └── Exclude: Purchasers, Cart Abandoners, Product Viewers
```

## Testing Audiences

### A/B Test Setup

```text
Campaign: Audience Test
├── Ad Set: Broad (control)
├── Ad Set: Interest Stack A / B
├── Ad Set: Lookalike 1%
└── Ad Set: Lookalike 3%

Same creative, same budget, same duration. Winner = best CPA.
```

**Duration:** minimum 7 days, ideal 14 days, need 100+ conversions per ad set.

| If Broad Wins | If Targeted Wins |
|---------------|------------------|
| Scale with broad | Layer targeting for efficiency |
| Creative is strong | Audience needs more specificity |
| Algorithm has good data | May need more conversion data |

---

*Next: [Retargeting Setup](retargeting-setup.md)*

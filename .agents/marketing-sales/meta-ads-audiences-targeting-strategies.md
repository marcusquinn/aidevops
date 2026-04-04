<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Targeting Strategies

> In 2026, targeting is less about finding people and more about giving Meta's AI the right signals.

## Targeting Hierarchy (Descending Effectiveness)

1. **Broad + Great Creative** — let AI find buyers
2. **Lookalike (1-3%)** — similar to best customers
3. **Custom Audiences** — first-party data
4. **Interest/Behavior Layering** — manual targeting
5. **Detailed Interest Only** — most restricted

---

## Broad Targeting

```
Location: [Target countries]
Age: 18-65+ (or product minimum)
Gender: All
Detailed Targeting: None
Advantage+ Audience: ON
```

**Use when:** 50+ conversions/week, creative clearly signals audience, want to scale.

**Avoid when:** Brand new account, very niche B2B, compliance restrictions, tiny TAM.

---

## Lookalike Audiences

### Source Quality

| Source | Quality |
|--------|---------|
| Closed-won customers (high LTV) | Best |
| All paying customers | Great |
| Sales-qualified leads | Good |
| Marketing-qualified leads | OK |
| All leads / Website visitors | Fair |
| Engagers | Poor |

### Build Steps

```
1. Prepare source: top 500-1000 customers by LTV (email, phone, name, country)
2. Audiences → Create → Custom Audience → Customer List → Upload
3. Audiences → Create → Lookalike → Source: custom audience → 1% to start
```

### Lookalike Sizes (US)

| % | Size | Quality |
|---|------|---------|
| 1% | ~2.3M | Highest |
| 2% | ~4.6M | High |
| 3% | ~6.9M | Good |
| 5% | ~11.5M | Medium |
| 10% | ~23M | Lower |

Start at 1%, expand when reach is needed.

### Stacked Lookalikes

Test sources in separate ad sets, let them compete:

```
Ad Set 1: LAL 1% - Customers (High LTV)
Ad Set 2: LAL 1% - All Customers
Ad Set 3: LAL 1% - Demo Completers
```

**Use lookalikes over broad when:** limited conversion history, specific customer profile, high-quality source, broad underperforming.

---

## Interest & Behavior Targeting

### B2B Interest Layering

```
Example (Marketing SaaS):
Interest: HubSpot OR Salesforce OR Marketo
AND Interest: Digital Marketing OR Content Marketing
AND Behavior: Small Business Owners
```

### B2C Interest Selection

Start with competitor brands, related products, lifestyle indicators, media consumed.

```
Example (Fitness):
Interest: CrossFit OR Orange Theory OR Peloton
AND Interest: Health & Wellness
```

### Interest Research

- **Audience Insights** — check what interests converters have, find adjacent interests
- **Facebook Ad Library** — see competitor targeting patterns
- **Customer surveys** — brands followed, publications read
- **Competitor lookalike** — target interest in competitor brand

### Behavior Options

| Behavior | Good For |
|----------|----------|
| Small Business Owners | B2B SMB |
| Business Page Admins | B2B, agency services |
| Technology Early Adopters | SaaS, tech products |
| Online Shoppers | Ecommerce |
| Frequent Travelers | Travel, luxury |

### Interest Testing Framework

**Week 1:**

```
Ad Set 1: Broad (control)
Ad Set 2: Interest Stack A
Ad Set 3: Interest Stack B
```

**Week 2 (if interest wins):** Test combinations, find best stack.

---

## First-Party Data

### Upload Match Rates

| Data Type | Match Rate | Notes |
|-----------|------------|-------|
| Email | 50-70% | Primary identifier |
| Phone | 30-50% | Secondary identifier |
| First/Last Name | Improves match | Always include |
| City/State | Improves match | Include if available |
| Country | Required | Always include |

### Segmentation

**By value:** High LTV (top 20%), all customers, high-spenders (by AOV)

**By behavior:** Recent purchasers (90d), repeat purchasers (2+ orders), lapsed (6+ months)

**By stage:** Leads not yet customers, trial users, churned customers

### Custom Audience Templates

**High-intent website:**

```
Pricing Page Visitors (7 days)
Demo Page Visitors (14 days)
Add to Cart (14 days)
Checkout Started (7 days)
```

**Engagement:**

```
Video Views 50%+ (30 days)
Video Views 95% (60 days)
Page Engagers (90 days)
Ad Engagers (30 days)
```

---

## Exclusion Strategy

**Exclude from prospecting:** recent purchasers (7-30d), current customers, employees.

**Exclude from retargeting:** already converted on this offer, higher-intent audiences in lower-intent campaigns.

```
Ad Set → Audience → Exclude People → Custom Audiences
```

### Retargeting Exclusion Waterfall

```
Campaign: Retargeting
├── Ad Set: Cart Abandoners
│   └── Exclude: Purchasers
├── Ad Set: Product Viewers
│   └── Exclude: Purchasers, Cart Abandoners
└── Ad Set: All Visitors
    └── Exclude: Purchasers, Cart Abandoners, Product Viewers
```

---

## Audience Testing

### A/B Test Setup

```
Campaign: Audience Test
├── Ad Set: Broad (control)
├── Ad Set: Interest-based
├── Ad Set: Lookalike 1%
└── Ad Set: Lookalike 3%

Same creative, same budget, same duration — winner = best CPA
```

**Duration:** 7 days minimum, 14 days ideal. Need 100+ conversions per ad set.

### Reading Results

| If Broad Wins | If Targeted Wins |
|---------------|------------------|
| Scale with broad | Layer targeting for efficiency |
| Creative is strong | Consider more specific audience |
| Algorithm has good data | May need more conversion data |

---

*Next: [Retargeting Setup](retargeting-setup.md)*

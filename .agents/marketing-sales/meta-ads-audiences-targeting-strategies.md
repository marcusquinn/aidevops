# Targeting Strategies

> In 2026, targeting is less about finding people and more about giving Meta's AI the right signals.

---

## The Targeting Hierarchy

| Priority | Method | Description |
|---|---|---|
| 1 | Broad + Great Creative | Let AI find buyers |
| 2 | Lookalike (1-3%) | Similar to best customers |
| 3 | Custom Audiences | Your first-party data |
| 4 | Interest/Behavior Layering | Manual targeting |
| 5 | Detailed Interest Only | Most restricted |

---

## Broad Targeting

Minimal restrictions, letting Meta's algorithm find buyers.

**Setup:**

```text
Location: [Your target countries]
Age: 18-65+ (or product minimum)
Gender: All
Detailed Targeting: None
Advantage+ Audience: ON
```

### Why Broad Works in 2026

| Meta's Algorithm | Your Manual Targeting |
|---|---|
| Billions of data points per user | Hypotheses about your customer |
| Real-time optimization across placements | Limited data points |
| Learning from your conversion data | Static assumptions |
| Cross-advertiser insights | — |

Broad + good creative often beats detailed targeting.

### When to Use Broad

| Works ✅ | Doesn't Work ❌ |
|---|---|
| 50+ conversions/week | Brand new account (no data) |
| Creative clearly signals who it's for | Very niche B2B product |
| Want to scale | Compliance/legal restrictions |
| Trust the algorithm | Very small total addressable market |

---

## Lookalike Audiences

### Source Quality

| Source Audience | Quality |
|---|---|
| Closed-won customers (high LTV) | Best |
| All paying customers | Great |
| Sales-qualified leads | Good |
| Marketing-qualified leads | OK |
| All leads / Website visitors | Fair |
| Engagers | Poor |

### Building Lookalikes

```text
Step 1 — Prepare source: Top 500-1000 customers by LTV, CSV with email/phone/name/country
Step 2 — Custom Audience: Audiences → Create → Customer List → Upload
         Name: "Customers - High LTV - 2026"
Step 3 — Lookalike: Audiences → Create → Lookalike → Source: above → Location → Size: 1%
```

### Lookalike Percentages

| % | Audience Size (US) | Quality |
|---|---|---|
| 1% | ~2.3M | Highest |
| 2% | ~4.6M | High |
| 3% | ~6.9M | Good |
| 5% | ~11.5M | Medium |
| 10% | ~23M | Lower |

Start at 1%, expand when you need reach.

### Stacked Lookalikes

Test different sources in separate ad sets to find the best-performing source:

```text
Ad Set 1: LAL 1% - Customers (High LTV)
Ad Set 2: LAL 1% - All Customers
Ad Set 3: LAL 1% - Demo Completers
```

### When Lookalikes Beat Broad

- Account has limited conversion history
- Very specific customer profile
- Source audience is high quality and unique
- Broad isn't performing

---

## Interest & Behavior Targeting

### B2B Interest Layering

```text
Example for Marketing SaaS:
Interest: HubSpot OR Salesforce OR Marketo
AND Interest: Digital Marketing OR Content Marketing
AND Behavior: Small Business Owners
```

### B2C Interest Selection

Competitor brands, related products, lifestyle indicators, media they consume.

```text
Example for Fitness Product:
Interest: CrossFit OR Orange Theory OR Peloton
AND Interest: Health & Wellness
```

### Interest Research Methods

| Method | How |
|---|---|
| Audience Insights (Ads Manager) | Check interests of converters; find adjacent interests |
| Facebook Ad Library | See what competitors target; identify patterns |
| Customer Surveys | Ask what brands/publications they follow |
| Competitor Lookalike | Target interest in competitor brand |

### Behavior Targeting Options

| Behavior | Good For |
|---|---|
| Small Business Owners | B2B SMB |
| Business Page Admins | B2B, agency services |
| Technology Early Adopters | SaaS, tech products |
| Online Shoppers | Ecommerce |
| Frequent Travelers | Travel, luxury |

### Interest Testing Framework

```text
Week 1 — Broad vs Interest Test:
  Ad Set 1: Broad (no interests)
  Ad Set 2: Interest Stack A
  Ad Set 3: Interest Stack B

Week 2 — If interest wins: test combinations, find best stack
```

---

## First-Party Data Strategy

### Data Types

| Data Type | Match Rate | Best Use |
|---|---|---|
| Email | 50-70% | Primary identifier |
| Phone | 30-50% | Secondary identifier |
| First/Last Name | Improves match | Always include |
| City/State | Improves match | Include if available |
| Country | Required | Always include |

### Segmentation

| Dimension | Segments |
|---|---|
| By Value | High LTV (top 20%), All customers, High-spenders (by AOV) |
| By Behavior | Recent purchasers (90d), Repeat purchasers (2+), Lapsed (6+ months) |
| By Stage | Leads not yet customers, Trial users, Churned customers |

### Custom Audience Examples

```text
High-Intent Website:
  Pricing Page Visitors (7d) · Demo Page Visitors (14d)
  Add to Cart (14d) · Checkout Started (7d)

Engagement:
  Video Views 50%+ (30d) · Video Views 95% (60d)
  Page Engagers (90d) · Ad Engagers (30d)
```

---

## Exclusion Strategy

### Who to Exclude

| Campaign Type | Exclude |
|---|---|
| Prospecting | Recent purchasers (7-30d), Current customers (CRM list), Employees |
| Retargeting | Already converted on this offer, Higher-intent audiences (in lower-intent ad sets) |

Exclusions: `Ad Set → Audience → Exclude People → Custom Audiences`.

### Exclusion Waterfall for Retargeting

```text
Campaign: Retargeting
├── Ad Set: Cart Abandoners
│   └── Exclude: Purchasers
├── Ad Set: Product Viewers
│   └── Exclude: Purchasers, Cart Abandoners
└── Ad Set: All Visitors
    └── Exclude: Purchasers, Cart Abandoners, Product Viewers
```

---

## Testing Audiences

### A/B Test Setup

```text
Campaign: Audience Test (same creative, budget, duration)
├── Ad Set: Broad (control)
├── Ad Set: Interest-based
├── Ad Set: Lookalike 1%
└── Ad Set: Lookalike 3%
Winner = best CPA
```

Duration: minimum 7 days, ideal 14 days, need 100+ conversions per ad set.

### Reading Results

| If Broad Wins | If Targeted Wins |
|---|---|
| Scale with broad | Layer targeting for efficiency |
| Creative is strong | Consider audience more specific |
| Algorithm has good data | May need more conversion data |

---

*Next: [Retargeting Setup](retargeting-setup.md)*

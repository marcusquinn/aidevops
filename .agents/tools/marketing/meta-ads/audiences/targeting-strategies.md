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

```
Location: [Your target countries]
Age: 18-65+ (or product minimum)
Gender: All
Detailed Targeting: None
Advantage+ Audience: ON
```

Meta has billions of data points, real-time cross-placement optimization, and learns from your conversion data. Broad + good creative often beats detailed targeting.

| Broad Works When | Broad Fails When |
|------------------|------------------|
| 50+ conversions/week | Brand new account (no data) |
| Creative clearly signals audience | Very niche B2B product |
| Scaling phase | Very small TAM |

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

### Building Lookalikes

```
1. Prepare source: Top 500-1000 customers by LTV (email, phone, name, country as CSV)
2. Audiences → Create Audience → Custom Audience → Customer List → Upload
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

Start at 1%, expand when you need reach. Test different sources in separate ad sets:

```
Ad Set 1: LAL 1% - Customers (High LTV)
Ad Set 2: LAL 1% - All Customers
Ad Set 3: LAL 1% - Demo Completers
```

**Lookalikes beat broad when:** limited conversion history, very specific customer profile, or broad isn't performing.

## Interest & Behavior Targeting

```
B2B (Marketing SaaS): Interest: HubSpot OR Salesforce AND Behavior: Small Business Owners
B2C (Fitness):        Interest: CrossFit OR Peloton AND Interest: Health & Wellness
```

**Interest research:** Audience Insights (check converter interests), Facebook Ad Library (competitor patterns), customer surveys (brands/publications), competitor brand as interest.

| Behavior | Good For |
|----------|----------|
| Small Business Owners | B2B SMB |
| Business Page Admins | B2B, agency services |
| Technology Early Adopters | SaaS, tech products |
| Online Shoppers | Ecommerce |
| Frequent Travelers | Travel, luxury |

## First-Party Data Strategy

| Data Type | Match Rate |
|-----------|------------|
| Email | 50-70% |
| Phone | 30-50% |
| First/Last Name + Country | Improves match |

**Segmentation:** High LTV (top 20%), recent purchasers (90d), repeat buyers (2+), lapsed (6+ months), leads not yet customers, trial users, churned.

**High-intent website audiences:** Pricing Page (7d), Demo Page (14d), Add to Cart (14d), Checkout Started (7d).

**Engagement audiences:** Video Views 50%+ (30d), Video Views 95% (60d), Page Engagers (90d), Ad Engagers (30d).

## Exclusion Strategy

**Prospecting:** exclude recent purchasers (7-30d), current customers, employees.
**Retargeting:** exclude already-converted, higher-intent audiences from lower-intent campaigns.

```
Campaign: Retargeting
├── Ad Set: Cart Abandoners      → Exclude: Purchasers
├── Ad Set: Product Viewers      → Exclude: Purchasers, Cart Abandoners
└── Ad Set: All Visitors         → Exclude: Purchasers, Cart Abandoners, Product Viewers
```

## Testing Audiences

```
Campaign: Audience Test
├── Ad Set: Broad (control)
├── Ad Set: Interest Stack A / B
├── Ad Set: Lookalike 1%
└── Ad Set: Lookalike 3%

Same creative, same budget, same duration. Winner = best CPA.
```

**Duration:** minimum 7 days, ideal 14 days, need 100+ conversions per ad set.

---

*Next: [Retargeting Setup](retargeting-setup.md)*

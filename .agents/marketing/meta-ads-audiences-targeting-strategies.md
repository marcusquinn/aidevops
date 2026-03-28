# Targeting Strategies

> In 2026, targeting is less about finding people and more about giving Meta's AI the right signals.

---

## The Targeting Hierarchy

**Most Effective (Descending Order):**

1. **Broad + Great Creative** — Let AI find buyers
2. **Lookalike (1-3%)** — Similar to best customers  
3. **Custom Audiences** — Your first-party data
4. **Interest/Behavior Layering** — Manual targeting
5. **Detailed Interest Only** — Most restricted

---

## Broad Targeting

### What Is Broad Targeting?

Minimal restrictions, letting Meta's algorithm find buyers.

**Setup:**
```
Location: [Your target countries]
Age: 18-65+ (or product minimum)
Gender: All
Detailed Targeting: None
Advantage+ Audience: ON
```

### Why Broad Works in 2026

**Meta's Algorithm Has:**
- Billions of data points per user
- Real-time optimization across placements
- Learning from your conversion data
- Cross-advertiser insights

**Your Manual Targeting Has:**
- Hypotheses about your customer
- Limited data points
- Static assumptions

**Result:** Broad + good creative often beats detailed targeting.

### When Broad Works

✅ You have 50+ conversions/week
✅ Your creative clearly signals who it's for
✅ You want to scale
✅ You trust the algorithm

### When Broad Doesn't Work

❌ Brand new account (no data)
❌ Very niche B2B product
❌ Compliance/legal restrictions
❌ Very small total addressable market

---

## Lookalike Audiences

### Source Audience Quality Matters

| Source Audience | Quality |
|-----------------|---------|
| Closed-won customers (high LTV) | Best |
| All paying customers | Great |
| Sales-qualified leads | Good |
| Marketing-qualified leads | OK |
| All leads | Fair |
| Website visitors | Fair |
| Engagers | Poor |

### Building High-Quality Lookalikes

**Step 1: Prepare Your Source**
```
Best: Top 500-1000 customers by LTV
Include: Email, phone, name, country
Format: CSV with clear headers
```

**Step 2: Create Custom Audience**
```
1. Audiences → Create Audience → Custom Audience
2. Customer List → Upload
3. Name: "Customers - High LTV - 2026"
```

**Step 3: Create Lookalike**
```
1. Audiences → Create Audience → Lookalike
2. Source: Your custom audience
3. Location: Target country
4. Size: 1% to start
```

### Lookalike Percentages

| Percentage | Audience Size (US) | Quality |
|------------|-------------------|---------|
| 1% | ~2.3M | Highest |
| 2% | ~4.6M | High |
| 3% | ~6.9M | Good |
| 5% | ~11.5M | Medium |
| 10% | ~23M | Lower |

**Start at 1%, expand when you need reach.**

### Stacked Lookalikes

Test different sources in separate ad sets:

```
Ad Set 1: LAL 1% - Customers (High LTV)
Ad Set 2: LAL 1% - All Customers
Ad Set 3: LAL 1% - Demo Completers
```

Let them compete, see which source produces best results.

### When Lookalikes Beat Broad

- Account has limited conversion history
- Very specific customer profile
- Source audience is high quality and unique
- Broad isn't performing

---

## Interest & Behavior Targeting

### B2B Interest Layering

**Strategy: Stack Related Interests**

```
Example for Marketing SaaS:
Interest: HubSpot OR Salesforce OR Marketo
AND
Interest: Digital Marketing OR Content Marketing
AND
Behavior: Small Business Owners
```

### B2C Interest Selection

**Start with:**
- Competitor brands
- Related products they'd buy
- Lifestyle indicators
- Media they consume

**Example for Fitness Product:**
```
Interest: CrossFit OR Orange Theory OR Peloton
AND
Interest: Health & Wellness
```

### Interest Research Methods

**1. Audience Insights (In Ads Manager)**
- Check what interests your converters have
- Find adjacent interests

**2. Facebook Ad Library**
- See what competitors target
- Identify patterns

**3. Customer Surveys**
- Ask what brands they follow
- What publications they read

**4. Competitor Lookalike**
- Target interest in competitor brand
- If they like competitor, they might like you

### Behavior Targeting Options

| Behavior | Good For |
|----------|----------|
| Small Business Owners | B2B SMB |
| Business Page Admins | B2B, agency services |
| Technology Early Adopters | SaaS, tech products |
| Online Shoppers | Ecommerce |
| Frequent Travelers | Travel, luxury |

### Interest Testing Framework

**Week 1: Broad vs Interest Test**
```
Ad Set 1: Broad (no interests)
Ad Set 2: Interest Stack A
Ad Set 3: Interest Stack B
```

**Evaluate:** Does interest targeting beat broad?

**Week 2: If Interest Wins, Optimize**
```
Test different interest combinations
Find best performing stack
```

---

## First-Party Data Strategy

### Data Types You Can Upload

| Data Type | Match Rate | Best Use |
|-----------|------------|----------|
| Email | 50-70% | Primary identifier |
| Phone | 30-50% | Secondary identifier |
| First/Last Name | Improves match | Always include |
| City/State | Improves match | Include if available |
| Country | Required | Always include |

### Segmentation Ideas

**By Value:**
- High LTV customers (top 20%)
- All customers
- High-spenders (by AOV)

**By Behavior:**
- Recent purchasers (90 days)
- Repeat purchasers (2+ orders)
- Lapsed customers (no purchase 6+ months)

**By Stage:**
- Leads not yet customers
- Trial users
- Churned customers

### Creating Valuable Custom Audiences

**High-Intent Website Audiences:**
```
Pricing Page Visitors (7 days)
Demo Page Visitors (14 days)
Add to Cart (14 days)
Checkout Started (7 days)
```

**Engagement Audiences:**
```
Video Views 50%+ (30 days)
Video Views 95% (60 days)
Page Engagers (90 days)
Ad Engagers (30 days)
```

---

## Exclusion Strategy

### Who to Exclude

**Always Exclude from Prospecting:**
- Recent purchasers (7-30 days)
- Current customers (if using CRM list)
- Employees (if significant number)

**Exclude from Retargeting:**
- Already converted on this offer
- Higher-intent audiences (in lower-intent campaigns)

### Setting Up Exclusions

```
Ad Set → Audience → Exclude People
→ Custom Audiences → Select audience to exclude
```

### Exclusion Waterfall for Retargeting

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

## Testing Audiences

### A/B Test Setup

**Test Broad vs Targeted:**
```
Campaign: Audience Test
├── Ad Set: Broad (control)
├── Ad Set: Interest-based
├── Ad Set: Lookalike 1%
└── Ad Set: Lookalike 3%

Same creative, same budget, same duration
Winner = best CPA
```

### Audience Test Duration

- Minimum: 7 days
- Ideal: 14 days  
- Need: 100+ conversions per ad set

### Reading Results

| If Broad Wins | If Targeted Wins |
|---------------|------------------|
| Scale with broad | Layer targeting for efficiency |
| Creative is strong | Consider audience more specific |
| Algorithm has good data | May need more conversion data |

---

*Next: [Retargeting Setup](retargeting-setup.md)*

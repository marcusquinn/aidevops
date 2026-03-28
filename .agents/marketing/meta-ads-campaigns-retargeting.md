# Retargeting Campaign

> Retargeting converts warm audiences into customers. It's your most efficient spend — but also the most limited.

---

## Retargeting Fundamentals

### What Is Retargeting?

Showing ads to people who have already interacted with your brand: visited your website, engaged with content, started but didn't complete a purchase, or are existing customers.

**The Numbers:** 2% of visitors convert on first visit. 98% leave without buying. Retargeted visitors are 70% more likely to convert. 3-7 touchpoints before purchase is typical.

### The Incrementality Warning

Retargeting has the LOWEST incrementality of any campaign type.

| Campaign Type | Typical Incrementality |
|---------------|----------------------|
| Retargeting (cart abandoners) | 20-40% |
| Retargeting (site visitors) | 40-60% |
| Prospecting (lookalike) | 60-80% |
| Prospecting (broad) | 70-90% |

Many retargeting conversions would have happened anyway. CPA looks amazing, but true value is lower. Don't over-invest.

### Retargeting vs Prospecting Budget

Retargeting audience is LIMITED (finite pool). Prospecting creates the retargeting pool. Without prospecting, retargeting pool shrinks.

```
Prospecting → Creates website visitors
Website visitors → Become retargeting pool
Retargeting → Converts warm visitors
Conversions → Fund more prospecting
```

---

## Audience Architecture

### Website Visitor Audiences

**By Page Type:**
| Audience | Setup | Best Use |
|----------|-------|----------|
| All visitors | URL contains [domain] | General retargeting |
| Product viewers | URL contains /products/ | Product interest |
| Pricing page | URL contains /pricing | High intent |
| Cart abandoners | Event: AddToCart, exclude Purchase | Highest intent |
| Blog readers | URL contains /blog/ | Content-based nurture |

**By Time Window:**
| Window | Audience Temperature | Typical CPA |
|--------|---------------------|-------------|
| 1-3 days | Hot | Lowest |
| 4-7 days | Warm | Low |
| 8-14 days | Cooling | Medium |
| 15-30 days | Cool | Higher |
| 31-180 days | Cold | Highest |

### Video Viewer Audiences

| Audience | Meaning | Best Use |
|----------|---------|----------|
| 3-second views | Saw your ad (minimal) | Large pool, low intent |
| 25% viewers | Showed interest | Mid-funnel content |
| 50% viewers | Engaged viewer | Consideration content |
| 75% viewers | Highly engaged | Conversion push |
| 95% viewers | Completed | Direct offer |
| ThruPlay | Watched 15s+ | Good for conversion |

### Engagement Audiences

- People who engaged with your Page (liked, commented, shared, messaged, saved, engaged with ads/events)
- Time windows: 30, 60, 90, 180, 365 days

### Customer Lists

| Segment | Best Use |
|---------|----------|
| All customers | Exclusion or lookalike source |
| Recent customers (90 days) | Upsell/cross-sell |
| Lapsed customers (>180 days) | Win-back campaign |
| High LTV customers | Lookalike source |
| Newsletter subscribers | Nurture to purchase |
| Free trial users | Conversion push |

### Naming Convention

```
RT_[SOURCE]_[WINDOW]_[SPECIFICS]

Examples:
RT_Web_7d_AllVisitors
RT_Web_14d_CartAbandoners
RT_Video_30d_75percent
RT_Engage_60d_PageEngagers
RT_List_Customers_All
```

---

## Retargeting Windows

### Optimal Windows by Industry

**E-commerce (Low Price Point <$100):**
| Window | Budget % | Message Focus |
|--------|----------|---------------|
| 1-3 days | 40% | Cart reminder, urgency |
| 4-7 days | 30% | Social proof, FOMO |
| 8-14 days | 20% | New offer, discount |
| 15-30 days | 10% | Final attempt |

**E-commerce (High Price Point >$500):**
| Window | Budget % | Message Focus |
|--------|----------|---------------|
| 1-7 days | 30% | More info, FAQ |
| 8-14 days | 25% | Testimonials, reviews |
| 15-30 days | 25% | Case studies, comparison |
| 31-60 days | 20% | Special offer |

**B2B SaaS:**
| Window | Budget % | Message Focus |
|--------|----------|---------------|
| 1-7 days | 20% | Value proposition |
| 8-14 days | 25% | Case study, results |
| 15-30 days | 25% | Demo offer |
| 31-90 days | 30% | Content nurture |

**Lead Gen:**
| Window | Budget % | Message Focus |
|--------|----------|---------------|
| 1-3 days | 35% | Form reminder |
| 4-7 days | 30% | Social proof |
| 8-14 days | 25% | Different angle |
| 15-30 days | 10% | Final push |

### The 180-Day Waste Problem

Avoid 180-day retargeting windows. Someone who visited 6 months ago probably forgot about you, may have solved their problem, and is basically cold traffic. Keep retargeting under 30-60 days. After 60 days, move to prospecting lookalike or use very light touch (awareness only).

---

## Frequency Management

| Audience | Max Frequency | Rationale |
|----------|---------------|-----------|
| Cart abandoners (3 days) | 5-7x | High intent, short window |
| Site visitors (7 days) | 3-4x | Still warm |
| Site visitors (14 days) | 2-3x | Cooling off |
| Engagers (30 days) | 2-3x | Casual interest |
| Engagers (60+ days) | 1-2x | Light touch |

**High frequency works when:** very hot audience, short window, different creative each impression, time-sensitive offer.

**High frequency hurts when:** same ad repeatedly, long window, no creative rotation, non-urgent message.

**Setting caps:** `Ad Set → Edit → Optimization & Delivery → Frequency Cap`. Or use Reach & Frequency buying type for guaranteed control. If you can't set caps, control frequency through budget (lower = lower frequency), audience size (bigger = lower frequency), and creative rotation.

| Placement | Acceptable Frequency |
|-----------|---------------------|
| Feed | 2-4x/week |
| Stories | 5-7x/week (fleeting) |
| Reels | 3-5x/week |
| Audience Network | 1-2x/week |

---

## Sequential Retargeting

Show different messages based on where someone is in their journey.

| Stage | User Behavior | Message Focus | Creative Type |
|-------|---------------|---------------|---------------|
| 1 | Page view only | Problem/solution intro | Educational video |
| 2 | Viewed products | Social proof, benefits | Testimonials |
| 3 | Added to cart | Overcome objections | FAQ, guarantees |
| 4 | Abandoned checkout | Urgency, discount | Offer with deadline |
| 5 | Purchased | Upsell/cross-sell | Related products |

**Creative examples:**

Stage 1: `"Discovered [Your Brand]? Here's what 10,000+ customers already know..." → Learn More`

Stage 2: `"Still thinking about [Product]? Here's what [Customer Name] said..." [testimonial] → See More Reviews`

Stage 3: `"Complete your order — [Product] is waiting. ✓ Free shipping ✓ 30-day returns ✓ 24/7 support → Complete Purchase"`

**Progressive offer strategy:**

| Stage | Offer | Why |
|-------|-------|-----|
| 1 | None | Build interest first |
| 2 | Free shipping | Low commitment |
| 3 | 10% off | Nudge to convert |
| 4 | 15% + urgency | Final push |
| 5 | N/A (purchased) | Upsell at full price |

Warning: Don't train customers to expect discounts. Use sparingly.

---

## Budget Allocation

| Site Traffic | RT % of Budget |
|--------------|----------------|
| <10K visitors/mo | 10-15% |
| 10-50K visitors/mo | 15-20% |
| 50-100K visitors/mo | 20-25% |
| 100K+ visitors/mo | 25-30% |

**Prioritize by intent:**
| Segment | Budget Priority |
|---------|-----------------|
| Cart abandoners | 30-40% of RT budget |
| Pricing/checkout visitors | 20-30% |
| Product viewers | 20-25% |
| All site visitors | 10-15% |
| Engagers only | 5-10% |

**Calculate expected value:**
```
Audience (Cart Abandoners): Size 1,000 × CVR 10% × Max CPA $30 = $3,000/month max budget
Audience (All Visitors): Size 10,000 × CVR 2% × Max CPA $30 = $6,000/month max budget
```

**Diminishing returns signals:** frequency >5 sustained, CPA rising while reach stays flat, negative feedback increasing, ROAS declining. Response: cap RT at 25-30% of total spend, shift budget to prospecting, build larger RT pool before increasing.

---

## Dynamic Ads (DPA)

Automatically show users products they've viewed, related products, or products they might like based on catalog data.

**Requirements:** Product catalog in Commerce Manager, Pixel with product events (ViewContent, AddToCart, Purchase), matching product IDs between pixel and catalog.

| Audience Type | Shows |
|---------------|-------|
| Viewed but not purchased | Exact products viewed |
| Added to cart | Cart items |
| Purchased | Cross-sell/upsell |
| Broad (prospecting) | Products likely to interest |

**Best practices:** High-quality product images, accurate prices, clear titles, in-stock items only. Add overlay (discount, free shipping). Exclude already purchased. Use product set filters (price >$20, category = bestsellers).

**Template copy:**
```
Primary text: {{product.name}} is waiting for you! | You viewed this — still interested?
Headline: Shop Now | {{product.price}} - Limited Stock | Free Shipping on {{product.name}}
```

---

## Campaign Structure

```
Campaign: Retargeting (CBO or ABO, Objective: Conversions)
├── Ad Set 1: Cart Abandoners (3 days)
│   ├── Audience: AddToCart, exclude Purchase, 3 days
│   ├── Exclude: Purchased last 7 days
│   └── Ads: Urgency, offer, product focus
├── Ad Set 2: High Intent Visitors (7 days)
│   ├── Audience: Pricing page, checkout page, 7 days
│   ├── Exclude: Cart abandoners, purchases
│   └── Ads: Testimonials, FAQ, guarantees
├── Ad Set 3: Site Visitors (14 days)
│   ├── Audience: All visitors, 14 days
│   ├── Exclude: Above audiences, purchases
│   └── Ads: Value prop, social proof
└── Ad Set 4: Engagers (30 days)
    ├── Audience: Video viewers, page engagers, 30 days
    ├── Exclude: Website visitors, purchases
    └── Ads: Educational, nurture content
```

**Exclusion waterfall:**
```
Cart Abandoners → Exclude Purchases
High Intent → Exclude Cart Abandoners, Purchases
Site Visitors → Exclude High Intent, Cart Abandoners, Purchases
Engagers → Exclude All Website Visitors, Purchases
```

---

## Retargeting Checklist

**Setup:** Pixel installed with all events · Custom audiences created · Proper exclusions in place · Descriptive naming convention

**Creative:** Different creative per audience segment · Messaging matches funnel stage · Offers appropriate to intent level · Dynamic ads for product viewers

**Monitoring:** Frequency under control (<5x weekly) · CPA meeting targets · Audience not shrinking · No negative feedback spikes

**Optimization:** Test new creative quarterly · Adjust windows based on data · Balance with prospecting spend · Review incrementality periodically

---

*Next: [Advantage+ Campaigns](advantage-plus.md)*

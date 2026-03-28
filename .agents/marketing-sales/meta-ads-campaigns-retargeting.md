# Retargeting Campaign

> Most efficient spend — but most limited pool and lowest incrementality. Don't over-invest.

## Fundamentals

Showing ads to people who already interacted with your brand (site visit, engagement, cart, existing customer). 2% convert on first visit; retargeted visitors 70% more likely to convert. 3-7 touchpoints before purchase is typical.

### Incrementality Warning

| Campaign Type | Typical Incrementality |
|---|---|
| Retargeting (cart abandoners) | 20-40% |
| Retargeting (site visitors) | 40-60% |
| Prospecting (lookalike) | 60-80% |
| Prospecting (broad) | 70-90% |

Many conversions would have happened anyway. CPA looks great; true value is lower.

Retargeting audience is finite. Prospecting creates the pool — without it, the pool shrinks: `Prospecting → Visitors → RT pool → Conversions → Fund more prospecting`.

---

## Audience Architecture

### Website Visitors

**By page type:**

| Audience | Setup | Best Use |
|---|---|---|
| All visitors | URL contains [domain] | General retargeting |
| Product viewers | URL contains /products/ | Product interest |
| Pricing page | URL contains /pricing | High intent |
| Cart abandoners | Event: AddToCart, exclude Purchase | Highest intent |
| Blog readers | URL contains /blog/ | Content-based nurture |

**By time window:**

| Window | Temperature | Typical CPA |
|---|---|---|
| 1-3 days | Hot | Lowest |
| 4-7 days | Warm | Low |
| 8-14 days | Cooling | Medium |
| 15-30 days | Cool | Higher |
| 31-180 days | Cold | Highest |

### Video Viewers

| Audience | Best Use |
|---|---|
| 3-second views | Large pool, low intent |
| 25% viewers | Mid-funnel content |
| 50% viewers | Consideration content |
| 75% viewers | Conversion push |
| 95% viewers | Direct offer |
| ThruPlay (15s+) | Good for conversion |

### Engagement & Customer Audiences

Page engagers (liked, commented, shared, messaged, saved, engaged with ads/events). Time windows: 30, 60, 90, 180, 365 days.

| Customer Segment | Best Use |
|---|---|
| All customers | Exclusion or lookalike source |
| Recent (90 days) | Upsell/cross-sell |
| Lapsed (>180 days) | Win-back campaign |
| High LTV | Lookalike source |
| Newsletter subscribers | Nurture to purchase |
| Free trial users | Conversion push |

### Naming: `RT_[SOURCE]_[WINDOW]_[SPECIFICS]`

Examples: `RT_Web_7d_AllVisitors`, `RT_Web_14d_CartAbandoners`, `RT_Video_30d_75percent`, `RT_Engage_60d_PageEngagers`, `RT_List_Customers_All`

---

## Retargeting Windows by Industry

| Industry | Window | Budget % | Message Focus |
|---|---|---|---|
| **E-com (<$100)** | 1-3 days | 40% | Cart reminder, urgency |
| | 4-7 days | 30% | Social proof, FOMO |
| | 8-14 days | 20% | New offer, discount |
| | 15-30 days | 10% | Final attempt |
| **E-com (>$500)** | 1-7 days | 30% | More info, FAQ |
| | 8-14 days | 25% | Testimonials, reviews |
| | 15-30 days | 25% | Case studies, comparison |
| | 31-60 days | 20% | Special offer |
| **B2B SaaS** | 1-7 days | 20% | Value proposition |
| | 8-14 days | 25% | Case study, results |
| | 15-30 days | 25% | Demo offer |
| | 31-90 days | 30% | Content nurture |
| **Lead Gen** | 1-3 days | 35% | Form reminder |
| | 4-7 days | 30% | Social proof |
| | 8-14 days | 25% | Different angle |
| | 15-30 days | 10% | Final push |

**180-day waste:** After 60 days, move to prospecting lookalike or awareness-only. Visitors from 6 months ago are effectively cold traffic.

---

## Frequency Management

| Audience | Max Frequency | Rationale |
|---|---|---|
| Cart abandoners (3 days) | 5-7x | High intent, short window |
| Site visitors (7 days) | 3-4x | Still warm |
| Site visitors (14 days) | 2-3x | Cooling off |
| Engagers (30 days) | 2-3x | Casual interest |
| Engagers (60+ days) | 1-2x | Light touch |

High frequency works with: hot audience, short window, creative rotation, time-sensitive offer. Hurts with: same ad repeated, long window, no rotation, non-urgent message.

**Setting caps:** `Ad Set → Edit → Optimization & Delivery → Frequency Cap`. Or use Reach & Frequency buying type. Without caps, control via budget (lower = lower frequency), audience size (bigger = lower frequency), and creative rotation.

**By placement:** Feed 2-4x/week · Stories 5-7x/week (fleeting) · Reels 3-5x/week · Audience Network 1-2x/week

---

## Sequential Retargeting

| Stage | User Behavior | Message Focus | Creative | Offer |
|---|---|---|---|---|
| 1 | Page view only | Problem/solution intro | Educational video | None (build interest) |
| 2 | Viewed products | Social proof, benefits | Testimonials | Free shipping |
| 3 | Added to cart | Overcome objections | FAQ, guarantees | 10% off |
| 4 | Abandoned checkout | Urgency, discount | Offer with deadline | 15% + urgency |
| 5 | Purchased | Upsell/cross-sell | Related products | Full price |

**Example copy:**

- **Stage 1:** `"Discovered [Brand]? Here's what 10,000+ customers already know..." → Learn More`
- **Stage 2:** `"Still thinking about [Product]? Here's what [Customer] said..." → See More Reviews`
- **Stage 3:** `"Complete your order — [Product] is waiting. ✓ Free shipping ✓ 30-day returns ✓ 24/7 support → Complete Purchase"`

Use discounts sparingly — don't train customers to expect them.

---

## Budget Allocation

| Site Traffic | RT % of Total Budget |
|---|---|
| <10K visitors/mo | 10-15% |
| 10-50K visitors/mo | 15-20% |
| 50-100K visitors/mo | 20-25% |
| 100K+ visitors/mo | 25-30% |

**By intent:** Cart abandoners 30-40% of RT budget · Pricing/checkout visitors 20-30% · Product viewers 20-25% · All site visitors 10-15% · Engagers only 5-10%

**Expected value:**

```text
Cart Abandoners: 1,000 × CVR 10% × Max CPA $30 = $3,000/month max
All Visitors: 10,000 × CVR 2% × Max CPA $30 = $6,000/month max
```

**Diminishing returns signals:** frequency >5 sustained, CPA rising while reach flat, negative feedback increasing, ROAS declining. Cap RT at 25-30% of total spend and shift to prospecting.

---

## Dynamic Ads (DPA)

Auto-show users products they've viewed or related items from catalog data. **Requirements:** Product catalog in Commerce Manager, Pixel with product events (ViewContent, AddToCart, Purchase), matching product IDs between pixel and catalog.

| Audience Type | Shows |
|---|---|
| Viewed but not purchased | Exact products viewed |
| Added to cart | Cart items |
| Purchased | Cross-sell/upsell |
| Broad (prospecting) | Products likely to interest |

**Best practices:** High-quality images, accurate prices, clear titles, in-stock only. Add overlay (discount, free shipping). Exclude already purchased. Use product set filters (price >$20, category = bestsellers).

**Template copy:**

```text
Primary: {{product.name}} is waiting for you! | You viewed this — still interested?
Headline: Shop Now | {{product.price}} - Limited Stock | Free Shipping on {{product.name}}
```

---

## Campaign Structure

```text
Campaign: Retargeting (CBO or ABO, Objective: Conversions)
├── Ad Set 1: Cart Abandoners (3d) — AddToCart excl Purchase — Urgency, offer
├── Ad Set 2: High Intent (7d) — Pricing/checkout excl cart/purchases — Testimonials, FAQ
├── Ad Set 3: Site Visitors (14d) — All visitors excl above — Value prop, social proof
└── Ad Set 4: Engagers (30d) — Video/page engagers excl web visitors — Nurture content
```

**Exclusion waterfall:** Each tier excludes all higher-intent tiers plus purchases: Cart → +High Intent → +Site Visitors → +Engagers.

---

## Checklist

- **Setup:** Pixel with all events · Custom audiences · Proper exclusions · Descriptive naming
- **Creative:** Different creative per segment · Messaging matches funnel stage · Offers match intent · Dynamic ads for product viewers
- **Monitoring:** Frequency <5x weekly · CPA on target · Audience not shrinking · No negative feedback spikes
- **Optimization:** New creative quarterly · Adjust windows from data · Balance with prospecting · Review incrementality periodically

---

*Next: [Advantage+ Campaigns](advantage-plus.md)*

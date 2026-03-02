# Retargeting Campaign

> Retargeting converts warm audiences into customers. It's your most efficient spend — but also the most limited.

---

## Table of Contents
1. [Retargeting Fundamentals](#retargeting-fundamentals)
2. [Audience Architecture](#audience-architecture)
3. [Retargeting Windows](#retargeting-windows)
4. [Frequency Management](#frequency-management)
5. [Sequential Retargeting](#sequential-retargeting)
6. [Budget Allocation](#budget-allocation)
7. [Dynamic Ads (DPA)](#dynamic-ads-dpa)

---

## Retargeting Fundamentals

### What Is Retargeting?

Showing ads to people who have already interacted with your brand:
- Visited your website
- Engaged with your content
- Started but didn't complete a purchase
- Are existing customers

### Why Retargeting Works

**The Numbers:**
- 2% of visitors convert on first visit
- 98% leave without buying
- Retargeted visitors are 70% more likely to convert
- 3-7 touchpoints before purchase is typical

### The Incrementality Warning

**Critical Understanding:**

Retargeting has the LOWEST incrementality of any campaign type.

| Campaign Type | Typical Incrementality |
|---------------|----------------------|
| Retargeting (cart abandoners) | 20-40% |
| Retargeting (site visitors) | 40-60% |
| Prospecting (lookalike) | 60-80% |
| Prospecting (broad) | 70-90% |

**What This Means:**
- Many retargeting conversions would have happened anyway
- You're "paying" for conversions that were coming regardless
- CPA looks amazing, but true value is lower

**Implication:**
Don't over-invest in retargeting. It looks efficient but has limits.

### Retargeting vs Prospecting Budget

**Common Mistake:**
"Retargeting has 2x ROAS of prospecting, let's shift all budget there!"

**Problem:**
- Retargeting audience is LIMITED (finite pool)
- Prospecting creates the retargeting pool
- Without prospecting, retargeting pool shrinks

**Correct Thinking:**
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
| 1-3 days | 🔥 Hot | Lowest |
| 4-7 days | 🔥 Warm | Low |
| 8-14 days | 🌡️ Cooling | Medium |
| 15-30 days | 🌡️ Cool | Higher |
| 31-180 days | ❄️ Cold | Highest |

### Video Viewer Audiences

**Engagement Levels:**
| Audience | Meaning | Best Use |
|----------|---------|----------|
| 3-second views | Saw your ad (minimal) | Large pool, low intent |
| 25% viewers | Showed interest | Mid-funnel content |
| 50% viewers | Engaged viewer | Consideration content |
| 75% viewers | Highly engaged | Conversion push |
| 95% viewers | Completed | Direct offer |
| ThruPlay | Watched 15s+ | Good for conversion |

### Engagement Audiences

**Facebook/Instagram Engagement:**
- People who engaged with your Page (liked, commented, shared)
- People who messaged your Page
- People who saved a post/ad
- People who engaged with your ads
- People who engaged with your events

**Time Windows:** 30, 60, 90, 180, 365 days

### Customer Lists

**Upload Sources:**
- Email lists (customers, subscribers)
- Phone numbers
- App user IDs
- Facebook user IDs

**Segmentation Ideas:**
| Segment | Best Use |
|---------|----------|
| All customers | Exclusion or lookalike source |
| Recent customers (90 days) | Upsell/cross-sell |
| Lapsed customers (>180 days) | Win-back campaign |
| High LTV customers | Lookalike source |
| Newsletter subscribers | Nurture to purchase |
| Free trial users | Conversion push |

### Building Audiences in Ads Manager

**Custom Audience Creation:**
```
1. Go to Audiences
2. Create Audience → Custom Audience
3. Select source:
   - Website
   - Customer List
   - App Activity
   - Engagement
4. Define criteria
5. Name descriptively: RT_Web_7d_Pricing
```

**Naming Convention:**
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

**Avoid 180-Day Retargeting Windows**

Someone who visited 6 months ago:
- Probably forgot about you
- May have solved their problem
- Is basically cold traffic
- Treating them as "warm" is expensive

**Better Approach:**
- Keep retargeting under 30-60 days
- After 60 days, move to prospecting lookalike
- Or use very light touch (awareness, not conversion)

---

## Frequency Management

### Frequency by Audience Temperature

| Audience | Max Frequency | Rationale |
|----------|---------------|-----------|
| Cart abandoners (3 days) | 5-7x | High intent, short window |
| Site visitors (7 days) | 3-4x | Still warm |
| Site visitors (14 days) | 2-3x | Cooling off |
| Engagers (30 days) | 2-3x | Casual interest |
| Engagers (60+ days) | 1-2x | Light touch |

### When High Frequency Is Okay

**High Frequency Works When:**
- Very hot audience (cart abandoners)
- Short time window (1-3 days)
- Different creative each impression
- Time-sensitive offer (sale ending)

**High Frequency Hurts When:**
- Same ad repeatedly (annoying)
- Long time window
- No creative rotation
- Non-urgent message

### Setting Frequency Caps

**In Ads Manager:**
```
Ad Set → Edit → Optimization & Delivery → Frequency Cap
```

**Or Use Reach & Frequency:**
For guaranteed frequency control, use Reach & Frequency buying type instead of Auction.

**Practical Approach:**
If you can't set caps, control frequency through:
- Budget (lower budget = lower frequency)
- Audience size (bigger audience = lower frequency)
- Creative rotation (multiple ads)

### Frequency by Placement

| Placement | Acceptable Frequency |
|-----------|---------------------|
| Feed | 2-4x/week |
| Stories | 5-7x/week (fleeting) |
| Reels | 3-5x/week |
| Audience Network | 1-2x/week |

---

## Sequential Retargeting

### What Is Sequential Retargeting?

Showing different messages based on where someone is in their journey.

**Traditional Retargeting:**
Everyone sees the same ad regardless of their stage.

**Sequential Retargeting:**
Different ads based on behavior and time.

### The Awareness → Consideration → Conversion Sequence

**Stage 1: Awareness (Just Visited)**
- Goal: Brand recognition
- Message: "Thanks for visiting! Here's what we do..."
- CTA: Learn More, Watch Video
- Audience: 1-3 day visitors, minimal engagement

**Stage 2: Consideration (Showed Interest)**
- Goal: Build trust
- Message: "Here's why customers love us..."
- CTA: See Reviews, Read Case Study
- Audience: 3-7 day visitors, product viewers

**Stage 3: Conversion (High Intent)**
- Goal: Close the sale
- Message: "Ready? Here's a special offer..."
- CTA: Buy Now, Start Trial
- Audience: Cart abandoners, pricing page

### Message Sequencing Framework

| Stage | User Behavior | Message Focus | Creative Type |
|-------|---------------|---------------|---------------|
| 1 | Page view only | Problem/solution intro | Educational video |
| 2 | Viewed products | Social proof, benefits | Testimonials |
| 3 | Added to cart | Overcome objections | FAQ, guarantees |
| 4 | Abandoned checkout | Urgency, discount | Offer with deadline |
| 5 | Purchased | Upsell/cross-sell | Related products |

### Creative Sequencing

**Don't Show the Same Ad**

Build creative specifically for each stage:

**Stage 1 Creative:**
```
"Discovered [Your Brand]? Here's what 10,000+ customers already know..."
[Educational content about your value]
CTA: Learn More
```

**Stage 2 Creative:**
```
"Still thinking about [Product]?"
"Here's what [Customer Name] said..."
[Video testimonial]
CTA: See More Reviews
```

**Stage 3 Creative:**
```
"Complete your order — [Product] is waiting"
✓ Free shipping
✓ 30-day returns
✓ 24/7 support
CTA: Complete Purchase
```

### Offer Sequencing

**The Progressive Offer Strategy:**

| Stage | Offer | Why |
|-------|-------|-----|
| 1 | None | Build interest first |
| 2 | Free shipping | Low commitment |
| 3 | 10% off | Nudge to convert |
| 4 | 15% + urgency | Final push |
| 5 | N/A (purchased) | Upsell at full price |

**Warning:** Don't train customers to expect discounts. Use sparingly.

---

## Budget Allocation

### Retargeting as % of Total Spend

**General Guidelines:**
| Site Traffic | RT % of Budget |
|--------------|----------------|
| <10K visitors/mo | 10-15% |
| 10-50K visitors/mo | 15-20% |
| 50-100K visitors/mo | 20-25% |
| 100K+ visitors/mo | 25-30% |

**Why Limited:**
- Retargeting audiences are finite
- Overspending = high frequency
- High frequency = ad fatigue, annoyed users

### Budget by Audience Segment

**Prioritize by Intent:**
| Segment | Budget Priority |
|---------|-----------------|
| Cart abandoners | 30-40% of RT budget |
| Pricing/checkout visitors | 20-30% |
| Product viewers | 20-25% |
| All site visitors | 10-15% |
| Engagers only | 5-10% |

### Diminishing Returns Signals

**Signs You're Overspending on Retargeting:**

- Frequency above 5x sustained
- CPA rising while reach stays flat
- Same users seeing ads repeatedly
- Negative feedback increasing
- ROAS declining

**Response:**
1. Reduce retargeting budget
2. Shift to prospecting
3. Build larger retargeting pool

---

## Dynamic Ads (DPA)

### What Are Dynamic Product Ads?

Automatically show users products they've viewed, related products, or products they might like based on catalog data.

### DPA Setup Requirements

**You Need:**
1. Product catalog in Commerce Manager
2. Pixel with product events (ViewContent, AddToCart, Purchase)
3. Matching product IDs between pixel and catalog

### DPA Audiences

| Audience Type | Shows |
|---------------|-------|
| Viewed but not purchased | Exact products viewed |
| Added to cart | Cart items |
| Purchased | Cross-sell/upsell |
| Broad (prospecting) | Products likely to interest |

### DPA Best Practices

**Catalog Quality:**
- High-quality product images
- Accurate prices
- Clear product titles
- Complete descriptions
- In-stock items only

**DPA Creative:**
- Use catalog's product images
- Add overlay (discount, free shipping)
- Card format for multiple products
- Single product for high intent

**DPA Optimization:**
- Optimize for purchases
- Use product set filters (price >$20, category = bestsellers)
- Exclude already purchased
- Set frequency caps

### DPA Template Setup

**Primary Text Options:**
```
{{product.name}} is waiting for you!
Back in stock: {{product.name}}
You viewed this — still interested?
Complete your look with {{product.name}}
```

**Headline Options:**
```
Shop Now
{{product.price}} - Limited Stock
Free Shipping on {{product.name}}
```

---

## Retargeting Campaign Structure

### Recommended Setup

```
Campaign: Retargeting
├── Budget Type: CBO or ABO
├── Objective: Conversions (Purchases/Leads)
│
├── Ad Set 1: Cart Abandoners (3 days)
│   ├── Audience: AddToCart, exclude Purchase, 3 days
│   ├── Exclude: Purchased last 7 days
│   └── Ads: Urgency, offer, product focus
│
├── Ad Set 2: High Intent Visitors (7 days)
│   ├── Audience: Pricing page, checkout page, 7 days
│   ├── Exclude: Cart abandoners, purchases
│   └── Ads: Testimonials, FAQ, guarantees
│
├── Ad Set 3: Site Visitors (14 days)
│   ├── Audience: All visitors, 14 days
│   ├── Exclude: Above audiences, purchases
│   └── Ads: Value prop, social proof
│
└── Ad Set 4: Engagers (30 days)
    ├── Audience: Video viewers, page engagers, 30 days
    ├── Exclude: Website visitors, purchases
    └── Ads: Educational, nurture content
```

### Exclusion Strategy

**Always Exclude:**
- Recent purchasers (7-30 days)
- Higher-intent audiences from lower-intent ad sets
- Anyone who shouldn't see ads (unsubscribers if possible)

**Exclusion Waterfall:**
```
Cart Abandoners → Exclude Purchases
High Intent → Exclude Cart Abandoners, Purchases
Site Visitors → Exclude High Intent, Cart Abandoners, Purchases
Engagers → Exclude All Website Visitors, Purchases
```

---

## Retargeting Checklist

### Setup:
- [ ] Pixel installed with all events
- [ ] Custom audiences created
- [ ] Proper exclusions in place
- [ ] Descriptive naming convention

### Creative:
- [ ] Different creative per audience segment
- [ ] Messaging matches funnel stage
- [ ] Offers appropriate to intent level
- [ ] Dynamic ads for product viewers

### Monitoring:
- [ ] Frequency under control (<5x weekly)
- [ ] CPA meeting targets
- [ ] Audience not shrinking
- [ ] No negative feedback spikes

### Optimization:
- [ ] Test new creative quarterly
- [ ] Adjust windows based on data
- [ ] Balance with prospecting spend
- [ ] Review incrementality periodically

---

## Advanced Retargeting Strategies

### Multi-Touch Retargeting Sequences

**The Full Journey Approach:**

```
Day 1 Visit → Educational Content (Brand Introduction)
           ↓
Day 3-5    → Social Proof (Testimonials, Reviews)
           ↓
Day 7-10   → Feature Highlights (What Makes Us Different)
           ↓
Day 14-21  → Objection Handling (FAQ, Guarantees)
           ↓
Day 21-30  → Offer/Urgency (Limited Time, Special Deal)
```

**Setting This Up:**

1. Create separate audiences for each window
2. Exclude previous stages from later stages
3. Create stage-specific creative
4. Use different messaging per stage

### Cross-Platform Retargeting

**Meta → Google Strategy:**
1. Run awareness on Meta (cheaper CPMs)
2. Retarget visitors on Google (higher intent context)
3. Use remarketing lists for search ads (RLSA)

**Meta → Email Strategy:**
1. Capture email on Meta (lead magnet)
2. Nurture via email sequence
3. Retarget email engagers on Meta
4. Exclude converters from all

### Segmented Product Retargeting

**For Multi-Product Businesses:**

```
Visitor to Category A → Show Category A products
Visitor to Category B → Show Category B products
Viewed Product X → Show Product X variations
Cross-sell: Bought A → Show complementary B
```

**Implementation:**
- Use URL-based audiences
- Create product sets in catalog
- Use Dynamic Product Ads with segments

### Engagement-Based Retargeting

**Tier Engagement Audiences:**

```
Tier 1 (Highest Engagement):
- 95% video viewers
- Page messengers
- Form starters (not submitted)

Tier 2 (Medium Engagement):
- 50% video viewers
- Post engagers
- Page visitors

Tier 3 (Light Engagement):
- 3-second video viewers
- Post reach
- Impression only
```

**Strategy:**
- Tier 1: Direct conversion ask
- Tier 2: More education, soft CTA
- Tier 3: Awareness content, build interest

### Abandoned Cart Email + Ads Sync

**Coordinated Approach:**

```
Hour 1: Abandoned cart email sent
Hour 3: If no open, show Meta ad (cart reminder)
Hour 24: Second email (urgency)
Day 2-3: Meta ad (social proof)
Day 4-7: Email + Meta ad (offer/discount)
```

**Why It Works:**
- Multiple touchpoints increase conversion
- Different channels reach different mindsets
- Coordinated message builds consistency

---

## Retargeting Budget Optimization

### Budget by Audience Value

**Calculate Expected Value:**

```
Audience A (Cart Abandoners):
- Size: 1,000
- Expected CVR: 10%
- AOV: $100
- Max CPA: $30
- Max Budget: 1,000 × 10% × $30 = $3,000/month

Audience B (All Visitors):
- Size: 10,000
- Expected CVR: 2%
- AOV: $100
- Max CPA: $30
- Max Budget: 10,000 × 2% × $30 = $6,000/month
```

### Diminishing Returns Detection

**Signs You're Overspending on RT:**

1. Frequency >5 weekly (fatigue)
2. CPA rising while reach stays flat
3. Negative feedback increasing
4. Conversions not growing with spend

**What to Do:**
- Cap RT at 25-30% of total spend
- Shift budget to prospecting
- Build larger RT pool before increasing

---

*Next: [Advantage+ Campaigns](advantage-plus.md)*

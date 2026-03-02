# How Meta's Algorithm Actually Works

> Understanding the algorithm is the difference between throwing money at ads and running profitable campaigns.

---

## Table of Contents
1. [The Auction System](#the-auction-system)
2. [Meta's ML Prediction Models](#metas-ml-prediction-models)
3. [The Learning Phase](#the-learning-phase)
4. [Account History & Trust](#account-history--trust)
5. [Pixel Data & Its Impact](#pixel-data--its-impact)
6. [Aggregated Event Measurement (AEM)](#aggregated-event-measurement-aem)
7. [Conversion API (CAPI)](#conversion-api-capi)
8. [The 2026 Algorithm Reality](#the-2026-algorithm-reality)

---

## The Auction System

Every time someone opens Facebook or Instagram, an auction occurs to determine which ad they see. This happens billions of times per day.

### The Three Factors

Meta's auction isn't just about who pays the most. It's a weighted score of three factors:

```
Total Value = Bid × Estimated Action Rate × Ad Quality
```

#### 1. Bid (What You're Willing to Pay)
- **Lowest Cost:** Meta tries to get you the most results for your budget
- **Cost Cap:** You set a maximum cost per result
- **Bid Cap:** You set a maximum bid per auction
- **ROAS Target:** Meta optimizes for return on ad spend

**Key Insight:** Higher bid ≠ guaranteed win. A $5 bid with low predicted engagement loses to a $2 bid with high predicted engagement.

#### 2. Estimated Action Rate (Will They Convert?)
This is Meta's ML prediction of how likely THIS specific person is to take YOUR desired action.

**How Meta Predicts:**
- Historical data from your campaigns
- User's past behavior (purchases, clicks, engagement)
- Content of your ad (image, video, text)
- Landing page quality
- Time of day, device, placement
- Hundreds of other signals

**Estimated Action Rate = Meta's prediction that this specific user will convert on your specific ad**

This is why creative matters so much — it directly affects this score.

#### 3. Ad Quality (User Experience)
Meta penalizes ads that create bad user experiences.

**Positive Signals:**
- High engagement (likes, comments, shares, saves)
- Video watch time
- Click-through rate
- Low negative feedback

**Negative Signals:**
- Hide ad / Report ad clicks
- Low engagement despite impressions
- Misleading claims
- Policy-violating content
- High bounce rate from landing page

**Quality = User Engagement - Negative Feedback**

### The Auction Math

```
Ad A: $3 bid × 2% estimated action rate × 0.8 quality = 0.048
Ad B: $2 bid × 3% estimated action rate × 1.0 quality = 0.060
Ad C: $5 bid × 1% estimated action rate × 0.7 quality = 0.035

Winner: Ad B (highest total value despite lowest bid)
```

### What This Means for Advertisers

1. **You can't buy your way to good results** — Quality and relevance matter more than budget
2. **Better creative = lower costs** — High engagement lowers your effective bid needed
3. **Poor ads get penalized** — Low-quality ads cost MORE to deliver, not less
4. **Relevance is everything** — Showing the right ad to the right person wins

---

## Meta's ML Prediction Models

Meta's machine learning is the most sophisticated advertising AI on the planet. Understanding it gives you an edge.

### How Predictions Work

When you create an ad, Meta immediately starts predicting:
- Who is likely to click
- Who is likely to convert
- What time they're most receptive
- Which placement will perform best
- What creative elements drive engagement

### The Data Meta Uses

**User Data:**
- Demographics (age, gender, location)
- Interests (inferred from behavior)
- Purchase history (on and off Facebook)
- Device usage patterns
- Content consumption patterns
- Social connections
- Time spent on different content types

**Ad Data:**
- Historical performance of your account
- Creative content analysis (images, video, text)
- Landing page content and quality
- Conversion data from Pixel/CAPI
- Similar advertisers' performance

**Contextual Data:**
- Time of day
- Day of week
- Seasonality patterns
- Competitive landscape
- Inventory availability

### The "Black Box" Problem

Meta doesn't tell you exactly how predictions work. But we know:

1. **More data = better predictions** — Accounts with history perform better
2. **Conversion events teach the algorithm** — Each conversion improves targeting
3. **Creative signals matter** — Meta analyzes ad content for audience matching
4. **Quality traffic compounds** — Good conversions lead to finding more good conversions

### How to Help the Algorithm

**Do:**
- Give it clear conversion signals (Pixel + CAPI)
- Use consistent creative styles so it learns what works
- Feed it quality data (good customers, not just leads)
- Let campaigns run long enough to learn

**Don't:**
- Change campaigns constantly (resets learning)
- Use low-quality conversion events (garbage in, garbage out)
- Fragment budgets across too many campaigns
- Fight the algorithm with overly narrow targeting

---

## The Learning Phase

When you launch a new campaign, ad set, or make significant changes, Meta enters a "Learning Phase."

### What's Actually Happening

During learning phase, Meta is:
1. Testing your ad across different audience segments
2. Gathering conversion data
3. Building a prediction model specific to your ad
4. Determining optimal delivery patterns

### Learning Phase Requirements

**Exit Criteria:**
- **50 optimization events** in the last 7 days per ad set
- OR **7 days** since launch (whichever comes first)
- Stable performance (not fluctuating wildly)

**What Counts as an Optimization Event:**
- Whatever you selected as your optimization goal
- Purchases, leads, clicks, video views, etc.

### Learning Phase Performance

**Expect During Learning:**
- Higher CPAs (20-50% above stable)
- Inconsistent daily performance
- Wider cost variations
- "Learning" or "Learning Limited" status

**After Learning Phase:**
- Stabilized CPAs
- More predictable daily performance
- Status changes to "Active"

### Learning Limited

If you see "Learning Limited," it means:
- Your ad set isn't getting enough optimization events
- Predictions will be less reliable
- Performance will be suboptimal

**Causes of Learning Limited:**
- Budget too low
- Audience too narrow
- Optimization event too rare
- Too many ad sets competing

**Fixes:**
| Problem | Solution |
|---------|----------|
| Low budget | Increase daily budget |
| Small audience | Broaden targeting |
| Rare event | Optimize for higher-funnel event |
| Too many ad sets | Consolidate |

### What Resets Learning Phase

Major edits trigger a learning phase reset:

| Change Type | Resets Learning? |
|-------------|------------------|
| New ad | No (ad set level) |
| Budget change >20% | Sometimes |
| Budget change <20% | No |
| Targeting change | Yes |
| Optimization event change | Yes |
| Bid strategy change | Yes |
| Creative change (all ads) | Yes |
| Pause >7 days | Yes |

**Best Practice:** Make small changes (≤20%) and wait 2-3 days between adjustments.

---

## Account History & Trust

Your account's history significantly impacts performance. New accounts start from scratch.

### How Account History Helps

**Established Accounts Get:**
- Faster learning phases
- Better initial predictions
- More delivery priority
- Lower CPMs in competitive auctions
- Access to certain features

**New Accounts Face:**
- Longer learning periods
- Higher initial CPAs
- More scrutiny (fraud detection)
- Feature limitations

### Building Account Trust

**Positive Signals:**
- Consistent spend over time
- Low refund/chargeback rates
- Policy compliance
- Positive user engagement
- Successful payment history

**Negative Signals:**
- Payment failures
- Policy violations
- High ad rejection rates
- Frequent dramatic changes
- User complaints

### The "Seasoning" Period

New accounts or new pixels need time to build trust.

**Recommendation:**
- Start with smaller budgets ($50-100/day)
- Run for 2-4 weeks before aggressive scaling
- Focus on quality conversions, not volume
- Avoid policy-edge content initially

---

## Pixel Data & Its Impact

The Meta Pixel is JavaScript code on your website that tracks user behavior and conversions.

### How Pixel Data Improves Delivery

Every Pixel fire teaches Meta:
1. **What converts** — User attributes that lead to conversions
2. **What doesn't** — Users who don't convert (negative signals)
3. **Content preferences** — Which products/pages attract which users
4. **Timing patterns** — When your audience is most active
5. **Device/placement** — Where conversions happen

### Essential Pixel Events

| Event | When to Fire | Purpose |
|-------|--------------|---------|
| PageView | Every page | Basic tracking |
| ViewContent | Product/key pages | Interest signals |
| AddToCart | Cart additions | Purchase intent |
| InitiateCheckout | Checkout start | High intent |
| Purchase | Completed orders | Conversion signal |
| Lead | Form submissions | Lead capture |
| CompleteRegistration | Account creation | Signup tracking |

### Event Priority (Post-iOS)

With Aggregated Event Measurement, you can only optimize for 8 events per domain, ranked by priority.

**Recommended Priority Order:**
1. Purchase
2. InitiateCheckout
3. AddToCart
4. Lead
5. CompleteRegistration
6. ViewContent
7. PageView
8. (Custom event)

### Pixel Health Check

**Signs of Healthy Pixel:**
- Events firing consistently
- Match rates >80%
- No duplicate events
- Proper value passing
- Event timing correct

**Common Pixel Issues:**
- Duplicate events (fires twice per action)
- Missing parameters (no value, no currency)
- Delayed firing (after redirect)
- Cross-domain issues (different pixels)

---

## Aggregated Event Measurement (AEM)

Apple's iOS 14+ privacy changes forced Meta to create AEM — a framework for tracking in a privacy-first world.

### How AEM Works

**Before iOS 14:**
- Pixel tracked everything
- Full user journey visible
- Unlimited events per domain
- Real-time attribution

**After iOS 14 (AEM):**
- 8 events max per domain
- Modeled conversions (not 100% accurate)
- 72-hour delayed reporting
- Aggregated data (less granular)

### AEM Limitations

| Limitation | Impact |
|------------|--------|
| 8 event limit | Can't optimize for minor events |
| 72-hour delay | Real-time optimization harder |
| Modeled data | ~30% of conversions estimated |
| No view-through (iOS) | Underreports display impact |
| Aggregate reporting | No user-level data |

### Working Within AEM

**Event Prioritization:**
Rank your 8 events by business importance. If user completes multiple events, only highest priority counts.

**Example Priority:**
```
1. Purchase (highest)
2. InitiateCheckout
3. AddToCart
4. Lead
5. ViewContent
6. Search
7. PageView
8. CustomEvent (lowest)
```

**Domain Verification:**
Required for AEM. Verify your domain in Business Settings to enable full tracking capabilities.

### Modeling & Estimation

Meta now "models" conversions it can't directly track:
- Statistical models based on historical patterns
- Aggregated data from opted-in users
- Machine learning predictions

**What This Means:**
- Your reported numbers are ~70-80% directly tracked
- ~20-30% are statistically modeled
- Directional accuracy is good, but exact numbers may vary
- Compare trends, not absolute numbers

---

## Conversion API (CAPI)

CAPI is server-side tracking that sends conversion data directly from your server to Meta — bypassing browser limitations.

### Why CAPI is Essential

**Pixel Limitations:**
- Blocked by ad blockers (20-30% of users)
- iOS App Tracking Transparency (80%+ opt-out)
- Browser privacy features
- Safari Intelligent Tracking Prevention
- Third-party cookie death

**CAPI Benefits:**
- Direct server-to-server connection
- Not affected by browser blockers
- More reliable data transmission
- Higher event match rates
- Better attribution accuracy

### CAPI + Pixel = Best Results

Don't choose one or the other. Use both.

```
User converts on website
       ↓
Pixel fires (client-side)  ←→  CAPI fires (server-side)
       ↓
Meta deduplicates
       ↓
Single conversion recorded
```

**Deduplication:**
Meta uses `event_id` to ensure the same conversion isn't counted twice.

### CAPI Implementation Options

| Method | Complexity | Cost | Reliability |
|--------|------------|------|-------------|
| Shopify/WooCommerce native | Easy | Free | Good |
| Google Tag Manager server | Medium | ~$100/mo | Great |
| Custom server integration | Hard | Dev time | Best |
| Third-party (Segment, etc.) | Medium | $200+/mo | Great |

### Key CAPI Parameters

**Required:**
- `event_name` — Purchase, Lead, etc.
- `event_time` — Unix timestamp
- `action_source` — website, app, etc.
- `event_source_url` — Page URL
- `user_data` — For matching

**User Data for Matching:**
- `em` — Email (hashed)
- `ph` — Phone (hashed)
- `fn` — First name (hashed)
- `ln` — Last name (hashed)
- `fbp` — FB Browser ID (from _fbp cookie)
- `fbc` — FB Click ID (from URL fbclid)

**Higher match rate = better optimization**

### CAPI Event Quality

Meta scores your CAPI implementation:

| Quality Score | Meaning |
|---------------|---------|
| Good | All working well |
| OK | Room for improvement |
| Poor | Fix immediately |
| N/A | Not enough data |

**Check in:** Events Manager → Data Sources → Select Pixel → Overview

---

## The 2026 Algorithm Reality

### The Shift to AI-First

Meta's algorithm in 2026 is fundamentally different from even 2023:

**Old Paradigm (Pre-2024):**
- Manual targeting with interests/behaviors
- Detailed audience layering
- Human-defined segments
- Creative as add-on

**New Paradigm (2025-2026):**
- Broad targeting, AI finds buyers
- Advantage+ as default
- Creative IS targeting
- Machine learning dominates

### What This Means for Advertisers

1. **Stop over-optimizing targeting**
   - Broad audiences often beat detailed targeting
   - Let the algorithm learn from conversion data
   - Your job is creative, not audience selection

2. **Creative quality is 70-80% of performance**
   - Algorithm optimizes delivery
   - You control the message
   - Better creative = lower CPMs, better results

3. **Feed the machine quality data**
   - CAPI implementation mandatory
   - First-party data is gold
   - Conversion quality matters more than quantity

4. **Think systems, not campaigns**
   - Testing → Scaling → Retargeting as a system
   - Continuous creative iteration
   - Account-level thinking

### Advantage+ Is the New Default

Meta is pushing all advertisers toward Advantage+ features:

| Feature | What It Does | When to Use |
|---------|--------------|-------------|
| Advantage+ Audience | AI finds your audience | Most campaigns |
| Advantage+ Placements | AI chooses placements | Always |
| Advantage+ Creative | AI tests variations | When you have volume |
| Advantage+ Shopping | Full auto ecom campaigns | Ecom with 50+ purchases/week |

**Manual still wins when:**
- Very niche B2B (tiny audiences)
- Creative testing (need control)
- Specific placement requirements
- Limited conversion data

---

## Key Takeaways

1. **The auction rewards relevance, not just budget**
   - Better creative + engagement = lower costs
   - Poor ads cost MORE to deliver

2. **Learning phase needs 50 conversions/week**
   - Don't make major changes during learning
   - Consolidate campaigns if not hitting threshold

3. **Account history matters**
   - New accounts need seasoning
   - Build trust through consistent quality

4. **Pixel + CAPI together**
   - Pixel alone misses 30-50% of conversions
   - CAPI is mandatory in 2026

5. **Let AI do its job**
   - Broad targeting + great creative beats micro-targeting
   - Focus on inputs (creative, data) not micro-management

---

*Next: [Attribution & Measurement](attribution.md)*

# CHAPTER 6: Direct Response Creative for E-Commerce

Every element either moves the needle or wastes budget. Optimize for immediate conversions.

## Product Photography

### The 3-Second Rule

Product image must instantly communicate: (1) what it is, (2) why it's desirable, (3) who it's for.

### Hero Shot Architecture

- **Lighting**: 45° front (soft diffusion), rim light for separation, fill for shadows, 5600K
- **Composition**: Product 70-80% of frame, rule of thirds, leading lines to features, clean negative space
- **Background**: White (#FFFFFF) for feeds; lifestyle for aspiration; gradient for depth; environmental blur (f/1.8-2.8)

### Angle Selection by Category

| Category | Primary angles |
|----------|---------------|
| Fashion/Apparel | Front (75%), 3/4 turn, detail, flat lay, on-model (face cropped) |
| Beauty/Cosmetics | 45° open product, swatches on diverse skin tones, before/after, hand-holding for scale |
| Home Goods | In-situ lifestyle (70% of conversions), multiple angles, detail, room-scene context |
| Tech/Electronics | Straight-on white BG, 45° showing ports, screen-on demos, size comparison, unboxing |

### The 5-Shot Framework

1. **Hero** — perfect product, white background
2. **Lifestyle** — aspirational use context
3. **Detail** — key feature/quality indicator
4. **Scale** — product with size reference
5. **Social proof** — product with 5-star rating overlay

### Photo Enhancement

- **Color correction**: consistent grading across line, +10-15% saturation for feed vibrancy, shadow lifting, highlight recovery
- **Retouching**: remove distractions; maintain authenticity; consistent model retouching (preserve skin texture); seamless background

### UGC-Style vs. Studio

| Style | When to use |
|-------|------------|
| UGC (natural light, smartphone, authentic settings, hands in frame) | Cold audience, high-consideration purchases, social proof categories (beauty, supplements) |
| Studio (controlled lighting, professional) | Retargeting, premium/luxury, technical products, brand awareness |

### Dynamic Creative Optimization (DCO)

- **Meta**: 10 product images per ad set; algorithm tests combinations
- **Google PMax**: 15+ images per asset group (mix landscape/square/portrait, product + lifestyle, text overlays on 50%)
- **Test variables**: background type, angle, composition, model vs. no model, context level

## Platform Specs Reference

### Image Specs

| Platform | Aspect Ratio | Resolution | Notes |
|----------|-------------|------------|-------|
| Facebook/Instagram Feed | 1:1 or 4:5 | 1080x1080px min | JPG or PNG, sRGB |
| Instagram Stories/Reels | 9:16 | 1080x1920px | Safe zone: center 1080x1680px |
| TikTok | 9:16 | 1080x1920px | No watermarks from other platforms |
| Pinterest | 2:3 | 1000x1500px | Long-form: 1000x2100px |
| Google Shopping/PMax | 1:1 or 1.91:1 | 800x800px min | Pure white BG, no text/logos |

### Carousel Specs

| Platform | Cards | Aspect Ratio | Resolution | Notes |
|----------|-------|-------------|------------|-------|
| Facebook/Instagram | 2-10 | 1:1 | 1080x1080px | 40 char headline, 20 word desc per card |
| LinkedIn | 2-10 | 1:1 or 4:5 | 1080x1080px | PDF upload → image carousel |
| TikTok | 10-35 | 1:1 or 9:16 | 1080x1080px | Auto-advance 1-3s, native music |
| Pinterest | 2-5 | 1:1 or 2:3 | 1000x1000px | Each card can link to different URL |

## Carousel Ad Strategies

### Card Hierarchy

- **Card 1 (Hook)**: Boldest visual, provocative headline, pattern interrupt, social proof indicator
- **Cards 2-4 (Build)**: Feature/benefit breakdowns, problem/solution, product variations, social proof
- **Card 5+ (Close)**: Urgency, guarantee/risk reversal, clear CTA, offer recap

### Narrative Structures

- **Feature Ladder**: Each card reveals a new feature, building desire
- **Problem-Agitate-Solve**: Problem → pain → solution → proof → close
- **Product Range**: Showcase variety for different segments
- **Social Proof Cascade**: Sequential customer evidence
- **Objection Crusher**: Address purchase hesitations sequentially

### Design Principles

- Visual cohesion: consistent palette, typography, branding
- Progressive disclosure: each card reveals new info, no redundancy
- Swipe incentive: arrows, cliffhanger headlines, incomplete visuals, numbered cards
- Mobile: 40px+ headlines, single focal point per card, high contrast

### Advanced Carousel Tactics

- **Catalog Carousel**: Dynamic population from product catalog — auto-shows relevant products, updates pricing, personalizes by behavior, retargets viewed products
- **Multi-Product**: Complementary products for basket building (complete outfit → items → "Get the complete look")
- **Tutorial**: Educational content leading to product (recipes/tips → product as tool)

## Dynamic Product Ads (DPA)

### Technical Foundation

**Events**: ViewContent, AddToCart, InitiateCheckout, Purchase, custom events.

**Catalog fields**: Product ID, title, description, price, availability, image URL, product URL, category, brand, condition, custom labels.

```text
Product Set: "All Products"
├── "Viewed Not Purchased" (custom audience)
├── "Added to Cart" (custom audience)
├── "High Value Products" (price > $100)
└── "New Arrivals" (date_added < 30 days)
```

### DPA Creative Templates

- **Single Product**: `[PRODUCT_IMAGE]` / `[PRODUCT_NAME]` / `[PRICE] [DISCOUNT_PRICE]` / `[RATING_STARS] ([REVIEW_COUNT])` / `[CTA_BUTTON]`
- **Multi-Product Carousel**: "You left these behind" → product cards with prices → "Complete your order → Free shipping over $50"
- **Collection**: Lifestyle/category hero + 4-product grid + "Shop [CATEGORY]"

### DPA Audience Segmentation

| Audience | Intent | Creative approach |
|----------|--------|------------------|
| Cart (7d), checkout (3d), viewed 3+ (7d) | Hot | High urgency, cart reminder, abandoned cart discount |
| Viewed product (14d), category (30d), engaged (30d) | Warm | Feature benefits, social proof, related products |
| Homepage (60d), engaged organic, lookalikes | Cool | Product discovery, bestsellers, new arrivals |

### DPA Customization

**Overlays**: price strikethrough, "Limited Stock", shipping badges, rating stars, "New"/"Sale" flags.

**Text by audience**:

- Cart abandoners: "Still thinking about [PRODUCT_NAME]? Complete your order + 10% off"
- Product viewers: "You viewed [PRODUCT_NAME]. Here's why customers love it..."
- Cross-sell: "Customers who bought [PURCHASED_PRODUCT] also love..."

**Advanced**: Cross-sell (co-purchase data), Up-sell (premium version of viewed), Seasonal (holiday/Valentine's/summer overlays), Location-specific (weather-triggered, regional, language localization).

## Retargeting Creative Sequences

### Retargeting Funnel

```text
Level 1: Site Visitors → Level 2: Product Viewers → Level 3: Cart Abandoners
→ Level 4: Checkout Initiators → Level 5: Purchasers (Cross-Sell)
```

### Level Strategy

| Level | Audience | Creative Goal | Timing | Freq Cap |
|-------|----------|--------------|--------|----------|
| 1 | Site visitors | Brand recall, value prop | 1-30d | 2/wk (10/30d) |
| 2 | Product viewers | Overcome objections, build desire | 1-30d | 3/wk (20/30d) |
| 3 | Cart abandoners | Overcome friction, urgency | 1h-3d | 2/day (30/7d) |
| 4 | Checkout initiators | Remove final barrier | 1h-2d | 3/day (40/3d) |
| 5 | Purchasers | Repeat purchase, basket expansion | 3-90d | 2/wk |

### Cart Abandoner Sequence (Level 3)

```text
Hour 1:  "You left [Product] in your cart. It's still available!"
Hour 4:  "[Product]: 4.8 stars, 5,200+ happy customers"
Day 1:   "Complete your order today: Free shipping + 10% off"
Day 2:   "Your cart expires in 24 hours. Items selling fast!"
Day 3:   "Last chance: Your cart + 15% off code inside"
```

### Progressive Offers & Discount Thresholds

Escalate discounts by time and intent level:

- **By time**: Day 1-7 no discount → Day 8-14 10% off → Day 15-21 15% + free shipping → Day 22-30 20% (final)
- **By intent**: Site visitors max 10% → Product viewers max 15% → Cart abandoners max 20% → Checkout abandoners max 25%

**Creative rotation** (avoid fatigue): Week 1 static → Week 2 video testimonials → Week 3 carousel → Week 4 UGC.

## Seasonal Creative

### E-Commerce Calendar

| Quarter | Key moments |
|---------|------------|
| Q1 | New Year/resolutions, Valentine's Day (Feb 1-14), Presidents' Day, Spring prep |
| Q2 | Easter, Mother's Day (critical), Memorial Day, Father's Day, graduation |
| Q3 | Independence Day, Prime Day, Back-to-school (huge), Labor Day, fall launch |
| Q4 | Halloween, BFCM (peak), Thanksgiving, Holiday shopping, year-end clearance |

### 45-Day Creative Development Window

| Phase | Timing | Activities |
|-------|--------|-----------|
| Strategy | Day -45 to -30 | Research trends, analyze last year, define angles, mood boards |
| Production | Day -30 to -15 | Photography, video, graphic design, copywriting |
| Pre-launch | Day -15 to -7 | Ad account setup, audience building, uploads, QA |
| Soft launch | Day -7 to 0 | Test small audiences, optimize, prepare to scale |
| Full launch | Day 0+ | Scale winners, real-time optimization |

### Seasonal Themes

| Season | Palette | Messaging Angles |
|--------|---------|-----------------|
| Valentine's Day | Red, pink, white, rose gold | Gift Guide, Show Your Love, Self-Love |
| Mother's Day | Pastels, soft pinks, lavender, gold | She Deserves This, Make Mom's Day |
| Back-to-School | Primary colors, chalkboard black | Gear Up, Crush This School Year |
| BFCM | Black, red, gold, high-contrast | Biggest Sale, [X]% Off Everything, Limited Stock |
| Holiday/Christmas | Red, green, gold, silver, winter whites | Perfect Gift for [Recipient], Last-Minute Ideas |

**Holiday phases (December)**: Phase 1 (Dec 1-10) gift guide → Phase 2 (Dec 11-18) urgency/shipping deadlines → Phase 3 (Dec 19-23) last-minute/digital gift cards → Phase 4 (Dec 24-31) after-Christmas/New Year.

### Evergreen vs. Seasonal Balance

- **80/20 rule**: 80% seasonal during peak windows, 20% evergreen fallback
- **Hybrid**: `[SEASONAL_OVERLAY] + Product Image + [EVERGREEN_COPY]` — swap overlay per season
- Swap seasonal creative within 48 hours of event end. Never show outdated seasonal creative.

## Promotional Creative

### Core Rule

Every promo ad must instantly communicate: (1) **The Offer**, (2) **The Value** (savings), (3) **The Deadline**.

### Promotional Frameworks

| Framework | Format | Best for |
|-----------|--------|---------|
| Percentage Off | "30% OFF EVERYTHING" | Sitewide sales, 30%+ discounts |
| Dollar Amount | "SAVE $50" | High-ticket ($200+), specific thresholds |
| Buy X Get Y | "BUY 2, GET 1 FREE" | Consumables, lower-priced, inventory clearance |
| Threshold | "$20 OFF ORDERS OVER $100" | Higher AOV, free shipping thresholds |
| Tiered | "Spend $100: 15% / $150: 20% / $200: 25% off" | Major sales, clearing inventory |
| Bundle | "COMPLETE THE SET: $150 (REG. $220)" | Complementary products, gift sets |

### Design Hierarchy

**Visual order**: Discount amount (largest, boldest) → Product (clear) → CTA button (contrasting) → Terms/deadline (small but legible).

**Color psychology**: Red (urgency, clearance) | Orange (flash sales) | Yellow (limited time) | Black/Gold (premium, BFCM) | Blue/Green (trust, steady promos).

**Text treatment**: "30% OFF" not "Get thirty percent off" | "ENDS TONIGHT" not "This promotion expires at 11:59 PM PST" | "SAVE $50" not "You could save up to fifty dollars".

**Badge placement**: Top-right "30% OFF", top-left "SALE", bottom banner "LIMITED TIME", diagonal ribbon "SAVE $50". Don't obscure product features.

### Urgency & Scarcity

- **Time-based**: Countdown timers ("FLASH SALE: 04:23:17 REMAINING"), deadlines ("ENDS TONIGHT", "LAST DAY - 6 HOURS LEFT")
- **Quantity-based**: Stock indicators ("ONLY 7 LEFT", "83% CLAIMED"), social proof ("2,341 SOLD IN 24 HOURS")

### Promotional Video (15s)

```text
0-3s:   Hook + Offer ("30% OFF EVERYTHING")
4-9s:   Product showcase (fast montage)
10-12s: Urgency ("ENDS TONIGHT")
13-15s: CTA ("SHOP NOW" + URL)
```

### Common Mistakes

| Mistake | Wrong | Right |
|---------|-------|-------|
| Confusing terms | "Up to 70% off select items, exclusions apply" | "30% off everything - No code needed" |
| Unclear deadline | "Limited time offer" | "Ends Sunday at midnight" |
| Weak contrast | Light yellow on white | Black on bright yellow |
| Hidden product | Discount overlay covering product | Small badge, product visible |
| Fake urgency | "Last Chance" running 2 weeks | Genuine deadlines, swap immediately after |

## AOV-Boosting Tactics

### Bundle Visualization

```text
Visual: All products arranged attractively
Text: "THE COMPLETE [CATEGORY] SET"
Pricing: Individual (crossed out): $50 + $40 + $35 = $125
         Bundle (prominent): $89
         Savings: "SAVE $36"
CTA: "Get the Bundle"
```

**Bundle types**: Complementary (Cleanser + Toner + Moisturizer = Complete Routine), Good-Better-Best (Starter/Fan Favorite/Lover), Seasonal (Host's Gift Set).

### Threshold Incentives

- **Free shipping**: Progress bar showing cart vs. threshold + suggested add-ons
- **Discount**: "Spend $100, Get 20% Off" + "You're $22 away from 20% off!"
- **Gift with purchase**: "Spend $75, Get [Product] FREE ($30 value)" + "You're $23 away!"

### Upsell Creative

- **Comparison**: Side-by-side Standard vs. Premium with feature checklist + "Upgrade to Premium" CTA
- **Social proof**: "Most Popular Choice" badge on premium; "78% choose Better"

### Value Stacking

```text
YOU GET:
✓ Product ($50 value)
✓ Free Shipping ($15 value)
✓ Bonus Accessory ($20 value)
✓ Extended Warranty ($30 value)
✓ 24/7 Support (Priceless)
Total Value: $115 | Your Price: $59 | YOU SAVE: $56
```

### Quantity Encouragement

- **Volume discount**: 1 unit $30 / 2 units $27 (10% off) / 3+ units $24 (20% off) — highlight "MOST POPULAR" on 3-pack
- **Stock-up**: "Most customers buy 3 for backups. Lasts 2 months each. 3 = 6-month supply."
- **Gift multiple**: "Keep One, Gift Two — Mom, Sister, Best Friend. 3 for $99 (Reg. $120)"

### AOV Testing

- **Variables**: bundle pricing, threshold amounts, upsell price points, quantity discount structures
- **Metrics**: AOV, units per transaction, bundle/upsell take rate, cart abandonment rate

### Platform-Specific AOV

- **Facebook Collection Ads**: Lifestyle hero + 4-product grid + "The Complete [Category] Collection" → Instant Experience
- **Instagram Shopping**: Tag multiple products, bundle pricing in caption
- **Google Shopping**: Supplemental feed for bundles, all products in single image, bundle price < sum

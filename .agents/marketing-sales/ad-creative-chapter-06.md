# CHAPTER 6: Direct Response Creative for E-Commerce

Direct response e-commerce creative lives and dies by immediate conversions. Every element either moves the needle or wastes budget.

## Product Photography

**3-second rule**: communicate (1) what it is, (2) why it's desirable, (3) who it's for.

**Hero shot**: Lighting — 45° front, soft diffusion, rim light, fill, 5600K. Composition — product 70-80% of frame, rule of thirds, leading lines, non-competing negative space. Background — white (#FFFFFF) for feeds; lifestyle for aspiration; gradient for depth; environmental blur (f/1.8-2.8) to isolate.

**5-shot framework**: (1) Hero — white background; (2) Lifestyle — aspirational context; (3) Detail — key feature; (4) Scale — size reference; (5) Social proof — 5-star rating overlay.

**Enhancement**: Color correction — consistent grading, +10-15% saturation, shadow lifting, highlight recovery. Retouching — remove distractions, maintain authenticity, preserve skin texture, seamless background.

**UGC-style** (natural light, smartphone quality, authentic settings, hands in frame): cold audience prospecting, high-consideration purchases, social proof categories (beauty, supplements). **Studio-style** (controlled lighting, professional): retargeting, premium/luxury, technical products, brand awareness.

**DCO — Meta**: 10 product images per ad set; algorithm tests combinations. **Google PMax**: 15+ images per asset group (landscape/square/portrait mix, product-only and lifestyle, text overlays on 50%). Test: background type, angle, composition, model vs. no model, context level.

### Angle Selection by Category

| Category | Primary angles |
|----------|---------------|
| Fashion/Apparel | Front (75%), 3/4 turn, detail, flat lay, on-model (face cropped) |
| Beauty/Cosmetics | 45° open product, swatches on diverse skin tones, before/after, hand-holding for scale |
| Home Goods | In-situ lifestyle (70% of conversions), multiple angles, detail, room-scene context |
| Tech/Electronics | Straight-on white background, 45° showing ports, screen-on demos, size comparison, unboxing |

### Platform Photo Specs

| Platform | Aspect Ratio | Resolution | Notes |
|----------|-------------|------------|-------|
| Facebook/Instagram Feed | 1:1 or 4:5 | 1080×1080px min | JPG (speed) or PNG (transparency), sRGB |
| Instagram Stories/Reels | 9:16 | 1080×1920px | Safe zone: center 1080×1680px |
| TikTok | 9:16 | 1080×1920px | No watermarks from other platforms |
| Pinterest | 2:3 | 1000×1500px | Long-form: 1000×2100px |
| Google Shopping/PMax | 1:1 or 1.91:1 | 800×800px min | Pure white background, no text overlays or logos |

## Carousel Ads

**Card structure**: Card 1 (Hook) — boldest visual, provocative headline, pattern interrupt, social proof indicator. Cards 2-4 (Build) — feature/benefit breakdowns, problem/solution, product variations, social proof. Card 5+ (Close) — urgency, guarantee/risk reversal, clear CTA, offer recap.

**Narrative structures**: Feature Ladder (each card reveals new feature) | PAS — Problem → pain → solution → proof → close | Product Range (showcase variety) | Social Proof Cascade (sequential customer evidence) | Objection Crusher (address hesitations sequentially).

**Design principles**: Visual cohesion (consistent palette, typography, branding); progressive disclosure (no redundancy); swipe incentive (arrows, cliffhangers, incomplete visuals, numbered cards); mobile optimization (40px+ headlines, single focal point, high contrast).

**Advanced tactics**: Catalog Carousel — auto-shows relevant products, updates pricing/availability, personalizes by behavior, retargets viewed products. Multi-Product Play — complementary products for basket building (complete outfit → individual items → "Get the complete look"). Tutorial Carousel — educational content leading to product (recipes/tips → product as the tool).

### Platform Carousel Specs

| Platform | Cards | Aspect Ratio | Resolution | Notes |
|----------|-------|-------------|------------|-------|
| Facebook/Instagram | 2-10 | 1:1 (recommended) | 1080×1080px | 40 char headline, 20 word description per card |
| LinkedIn | 2-10 | 1:1 or 4:5 | 1080×1080px | PDF upload converted to image carousel |
| TikTok | 10-35 | 1:1 or 9:16 | 1080×1080px | Auto-advance 1-3s, native music overlay |
| Pinterest | 2-5 | 1:1 or 2:3 | 1000×1000px | Each card can link to different URL |

## Dynamic Product Ads (DPA)

**Pixel/SDK events**: ViewContent, AddToCart, InitiateCheckout, Purchase, custom events.

**Catalog fields**: Product ID, title, description, price, availability, image URL, product URL, category, brand, condition, custom labels.

**Facebook/Instagram catalog structure**:

```
Product Set: "All Products"
├── "Viewed Not Purchased" (custom audience)
├── "Added to Cart" (custom audience)
├── "High Value Products" (price > $100)
└── "New Arrivals" (date_added < 30 days)
```

**Creative templates**: Single Product — `[PRODUCT_IMAGE]` / `[PRODUCT_NAME]` / `[PRICE] [DISCOUNT_PRICE]` / `[RATING_STARS] ([REVIEW_COUNT])` / `[CTA_BUTTON]`. Multi-Product Carousel — "You left these behind" → product cards → "Complete your order → Free shipping over $50". Collection — Lifestyle hero + 4-product grid + "Shop [CATEGORY]".

**Overlays**: price strikethrough, "Limited Stock" indicators, shipping badges, rating stars, "New"/"Sale" flags.

**Text by audience**: Cart abandoners — "Still thinking about [PRODUCT_NAME]? Complete your order + 10% off" | Product viewers — "You viewed [PRODUCT_NAME]. Here's why customers love it..." | Cross-sell — "Customers who bought [PURCHASED_PRODUCT] also love..."

**Advanced DPA**: Cross-sell (co-purchase data), Up-sell (premium version of viewed product), Seasonal (holiday/Valentine's/summer overlays), Location-specific (weather-triggered, regional preferences, language localization).

### DPA Audience Segmentation

| Audience | Intent | Creative approach |
|----------|--------|------------------|
| Added to cart (7d), initiated checkout (3d), viewed 3+ products (7d) | Hot | High urgency, cart reminder, abandoned cart discount |
| Viewed product (14d), viewed category (30d), engaged with ad (30d) | Warm | Feature benefits, social proof, related products |
| Visited homepage (60d), engaged with organic, lookalikes | Cool | Product discovery, bestsellers, new arrivals |

## Retargeting Creative Sequences

### Funnel Levels

| Level | Audience | Intent | Creative Goal | Timing | Frequency Cap |
|-------|----------|--------|--------------|--------|---------------|
| 1 | Site visitors | Low | Brand recall, value proposition | 1-30 days | 2/week |
| 2 | Product viewers | Medium | Overcome objections, build desire | 1-30 days | 3/week |
| 3 | Cart abandoners | High | Overcome friction, create urgency | 1h-3 days | 2/day |
| 4 | Checkout initiators | Very high | Remove final barrier, maximize urgency | 1h-2 days | 3/day |
| 5 | Purchasers | Satisfied | Repeat purchase, basket expansion | 3-90 days | 2/week |

### Cart Abandoner Sequence (Level 3)

```
Hour 1:  "You left [Product] in your cart. It's still available!"
Hour 4:  "[Product]: 4.8 stars, 5,200+ happy customers"
Day 1:   "Complete your order today: Free shipping + 10% off"
Day 2:   "Your cart expires in 24 hours. Items selling fast!"
Day 3:   "Last chance: Your cart + 15% off code inside"
```

**Progressive offers**: Day 1-7 no discount → Day 8-14 10% off → Day 15-21 15% off + free shipping → Day 22-30 20% off (final).

**Discount thresholds**: Site visitors max 10% → Product viewers max 15% → Cart abandoners max 20% → Checkout abandoners max 25%.

**Creative variety** (avoid ad fatigue): Week 1 static → Week 2 video testimonials → Week 3 carousel → Week 4 UGC.

**Frequency caps**: Site visitors 10/30d → Product viewers 20/30d → Cart abandoners 30/7d → Checkout abandoners 40/3d.

## Seasonal Creative Calendars

| Quarter | Key moments |
|---------|------------|
| Q1 | New Year/resolutions, Valentine's Day (Feb 1-14), Presidents' Day, Spring prep |
| Q2 | Easter, Mother's Day (critical), Memorial Day, Father's Day, graduation |
| Q3 | Independence Day, Prime Day, Back-to-school (huge), Labor Day, fall launch |
| Q4 | Halloween, Black Friday/Cyber Monday (peak), Thanksgiving, Holiday shopping, year-end clearance |

**45-day window**: Day -45 to -30 strategy & planning → Day -30 to -15 production → Day -15 to -7 pre-launch (ad setup, audience building, QA) → Day -7 to 0 soft launch (test, optimize) → Day 0+ full launch (scale winners).

**80/20 rule**: 80% seasonal during peak windows, 20% evergreen fallback. Hybrid: `[SEASONAL_OVERLAY] + Product Image + [EVERGREEN_COPY]` — swap overlay per season. Swap within 48 hours of event end.

### Seasonal Themes

| Season | Color Palette | Key Messaging Angles |
|--------|--------------|---------------------|
| Valentine's Day | Red, pink, white, rose gold | Gift Guide, Show Your Love, Self-Love Gifts |
| Mother's Day | Pastels, soft pinks, lavender, gold | She Deserves This, Make Mom's Day Special |
| Back-to-School | Primary colors, chalkboard black | Gear Up for Success, Crush This School Year |
| Black Friday/Cyber Monday | Black, red, gold, high-contrast | Biggest Sale of the Year, [X]% Off Everything, Limited Stock |
| Holiday/Christmas | Red, green, gold, silver, winter whites | Perfect Gift for [Recipient], Last-Minute Gift Ideas |

**December phases**: Phase 1 (Dec 1-10) gift guide → Phase 2 (Dec 11-18) urgency/shipping deadlines → Phase 3 (Dec 19-23) last-minute/digital gift cards → Phase 4 (Dec 24-31) after-Christmas/New Year positioning.

## Promotional Creative

Every promotional ad must instantly communicate: (1) **The Offer** — what's the deal? (2) **The Value** — how much do I save? (3) **The Deadline** — when does it end?

**Visual hierarchy**: Discount amount (largest, boldest) → Product (clear, high-quality) → CTA button (contrasting color) → Terms/deadline (small but legible).

**Color psychology**: Red (urgency, clearance, 50%+ off) | Orange (energy, flash sales) | Yellow (attention, limited time) | Black/Gold (premium sales, Black Friday) | Blue/Green (trust, value, steady promotions).

**Text treatment**: "30% OFF" not "Get thirty percent off your purchase" | "ENDS TONIGHT" not "This promotion expires at 11:59 PM PST" | "SAVE $50" not "You could save up to fifty dollars".

**Badge placement**: Top-right "30% OFF", top-left "SALE", bottom banner "LIMITED TIME", diagonal ribbon "SAVE $50". Don't obscure key product features.

**Urgency — time-based**: Countdown timers ("FLASH SALE: 04:23:17 REMAINING"), deadline messaging ("ENDS TONIGHT AT MIDNIGHT", "LAST DAY - SALE ENDS IN 6 HOURS"). **Quantity-based**: Stock indicators ("ONLY 7 LEFT IN STOCK", "SELLING FAST - 83% CLAIMED"), social proof scarcity ("2,341 SOLD IN LAST 24 HOURS").

**Promotional video (15s)**:

```
0-3s:   Hook + Offer ("30% OFF EVERYTHING")
4-9s:   Product showcase (fast-paced montage)
10-12s: Urgency ("ENDS TONIGHT")
13-15s: CTA ("SHOP NOW" button + URL)
```

### Messaging Frameworks

| Framework | Format | Best for |
|-----------|--------|---------|
| Percentage Off | "30% OFF EVERYTHING" | Sitewide sales, 30%+ discounts |
| Dollar Amount Off | "SAVE $50" | High-ticket items ($200+), specific thresholds |
| Buy X Get Y | "BUY 2, GET 1 FREE" | Consumables, lower-priced items, inventory clearance |
| Threshold Discount | "$20 OFF ORDERS OVER $100" | Higher AOV, free shipping thresholds |
| Tiered Offers | "Spend $100: 15% off / $150: 20% off / $200: 25% off" | Major sales events, clearing inventory |
| Bundle Deals | "COMPLETE THE SET: $150 (REG. $220)" | Complementary products, gift sets |

### Common Mistakes

| Mistake | Wrong | Right |
|---------|-------|-------|
| Confusing terms | "Up to 70% off select items, exclusions apply" | "30% off everything - No code needed" |
| Unclear deadline | "Limited time offer" | "Ends Sunday at midnight" |
| Weak contrast | Light yellow text on white | Black text on bright yellow |
| Hidden product | Discount overlay covering product | Small badge, product clearly visible |
| Fake urgency | "Last Chance" ads running 2 weeks | Genuine deadlines, swap creative immediately after |

## AOV-Boosting Creative

**Bundle visualization**:

```
Visual: All products in bundle arranged attractively
Text: "THE COMPLETE [CATEGORY] SET"
Pricing: Individual prices (crossed out): $50 + $40 + $35 = $125
         Bundle price (prominent): $89
         Savings callout: "SAVE $36"
CTA: "Get the Bundle"
```

**Bundle types**: Complementary (Cleanser + Toner + Moisturizer = Complete Routine), Good-Better-Best (Starter/Fan Favorite/Coffee Lover), Seasonal (Host's Gift Set).

**Threshold incentives**: Free shipping — progress bar showing cart value vs. threshold + suggested add-ons. Discount threshold — "Spend $100, Get 20% Off" + "You're $22 away from 20% off everything!" Gift with purchase — "Spend $75, Get [Premium Product] FREE ($30 value)" + "You're $23 away from your free gift."

**Upsell**: Side-by-side Standard vs. Premium with feature checklist and "Upgrade to Premium" CTA. "Most Popular Choice" badge on premium; "78% choose Better" social proof.

**Value stacking**:

```
YOU GET:
✓ Product ($50 value)
✓ Free Shipping ($15 value)
✓ Bonus Accessory ($20 value)
✓ Extended Warranty ($30 value)
✓ 24/7 Support (Priceless)
Total Value: $115 | Your Price Today: $59 | YOU SAVE: $56
```

**Quantity encouragement**: Volume discount — 1 unit $30 / 2 units $27 (10% off) / 3+ units $24 (20% off), highlight "MOST POPULAR" on 3-pack. Stock-up — "Most customers buy 3 to have backups. [Product] lasts 2 months each. Order 3 = 6-month supply." Gift multiple — "Keep One, Gift Two — Perfect for: Mom, Sister, Best Friend. 3 for $99 (Reg. $120)."

**Test variables**: bundle pricing, threshold amounts, upsell price points, quantity discount structures. **Key metrics**: AOV, units per transaction, take rate on bundles/upsells, cart abandonment rate.

**Facebook Collection Ads**: Lifestyle hero + 4-product grid + "The Complete [Category] Collection" → Instant Experience. **Instagram Shopping**: Tag multiple products in single image, bundle pricing in caption. **Google Shopping**: Supplemental feed for bundle listings, all products in single image, bundle price lower than sum.

---

## The Direct Response Creative Mindset

1. **Clarity over cleverness** — If it doesn't communicate instantly, it doesn't work
2. **Testing over opinions** — Data decides, egos don't
3. **Speed over perfection** — Ship fast, iterate faster
4. **Systems over one-offs** — Build scalable creative processes
5. **AOV over CPA** — Optimize for profit, not just acquisition cost

## Google Ads Creative

Google Ads matches intent (the search query), not interruption. Meta stops the scroll; Google answers the question.

### Google Search Ads — Responsive Search Ads (RSA)

Default search format. Provide up to 15 headlines + 4 descriptions; Google's ML tests combinations.

**Specs:**

| Element | Count | Char limit | Display |
|---------|-------|-----------|---------|
| Headlines | 3-15 (recommend 15) | 30 | 2-3 shown per ad |
| Descriptions | 2-4 (recommend 4) | 90 | 1-2 shown per ad |
| Path fields | 2 | 15 each | Green URL: `domain/path1/path2` |

- **Pinning:** Pin to H1/H2/H3 or D1/D2. Use sparingly — reduces ML flexibility. If pinning, pin 2-3 options to same position.
- **Ad Strength:** Aim for Good/Excellent. Factors: asset count, uniqueness, keyword inclusion.
- **Dynamic insertion:** `{KeyWord:Default Text}`, `{IF(device=mobile):Mobile|Desktop}`, `{LOCATION(City)}`, `{COUNTDOWN(2027/12/31 23:59:59)}`

**RSA Best Practices:**

1. **Maximize assets** — all 15 headlines + 4 descriptions
2. **Keyword inclusion** — primary keyword in 2+ headlines; use dynamic insertion
3. **Unique messaging** — each headline adds distinct value; no synonymous phrases
4. **Standalone readability** — every asset must make sense in any combination/order
5. **CTA variety** — mix Buy/Get/Try/Start/Download; test questions vs. statements
6. **Benefit + feature + proof mix** — balance across headlines
7. **Length variation** — mix short (15-20 char) and long (28-30 char)

**Headline Formula (15 headlines):**

```text
H1-H3:  Keyword-Rich — [Primary Keyword] - [Differentiator]
H4-H6:  Benefit-Focused — [Benefit] in [Timeframe] / [Problem Solved] - [Outcome]
H7-H9:  Offer/Promo — [Discount]% Off Today / Free [Bonus] With Purchase
H10-H12: Social Proof — Trusted by [N]+ [Customers] / [Rating]★ on [Platform]
H13-H15: CTAs — Shop [Category] Now / Get Your Free [Lead Magnet]
```

**Description Formula (4 descriptions, 90 char each):**

```text
D1: Value prop + top 3 benefits + differentiation
D2: Social proof (customer count/rating) + CTA
D3: Specific offer + urgency + CTA
D4: Key features list + ease of use + support/guarantee
```

**RSA Example — Project Management Software:**

```text
H1: Project Management Software     H6: Powerful Features, Simple Setup
H2: Manage Projects Efficiently      H7: 50% Off Your First Year
H3: Official ToolName Site           H8: Free 30-Day Trial - No Card
H4: Organize Projects in Minutes     H9: Limited Time: Free Onboarding
H5: Never Miss a Deadline Again      H10-15: [Social proof, awards, CTAs]

D1: Complete project management platform. Track tasks, collaborate in real-time, hit deadlines.
D2: Join 50,000+ successful teams. Rated 4.8/5 stars. Start your free 30-day trial today.
D3: Limited time: 50% off first year plus free onboarding. Offer ends soon. Claim discount now.
D4: Task management, time tracking, team chat, file sharing & more. 24/7 support included.
```

**Optimization Cycle:**

1. **Launch (days 1-14):** No changes. Let Google test. Need ~3,000 impressions minimum.
2. **Analyze (day 14+):** Review Asset Report — identify "Low" performers, check for messaging redundancy.
3. **Optimize (ongoing):** Replace "Low" assets, test new angles, add seasonal relevance. Maintain 10+ headlines, 3+ descriptions.

### Responsive Display Ads (RDA)

Auto-adjusts across Google Display Network (3M+ sites/apps).

**Specs:**

| Element | Dimensions / Limit | Required | Max count |
|---------|-------------------|----------|-----------|
| Landscape image (1.91:1) | 1200x628 (min 600x314) | Yes | 15 total |
| Square image (1:1) | 1200x1200 (min 300x300) | Yes | (included above) |
| Square logo (1:1) | 1200x1200 | Yes | 5 |
| Landscape logo (4:1) | 1200x300 | No | (included above) |
| Videos (YouTube only) | 16:9, 9:16, or 1:1; ≤30s | No | 5 |
| Short headlines | 30 char | Yes | 5 |
| Long headline | 90 char | Yes (1) | 1 |
| Descriptions | 90 char | Yes | 5 |
| Business name | 25 char | Yes | 1 |

File types: JPG/PNG/GIF (non-animated), max 5120 KB.

**RDA Best Practices:**

1. **Fill all slots** — 15 images, 5 logos, 5 headlines, 5 descriptions
2. **Image quality** — high-res, <20% text, product in context; mix product + lifestyle
3. **Logos** — transparent background, readable small, both square + landscape
4. **Text-in-image** — minimal; don't repeat ad copy; Google may crop
5. **Headlines** — short: punchy/benefit; long: full value prop with keyword
6. **Descriptions** — unique angle each; cover benefits, social proof, urgency, features, CTA

**RDA Asset Formula:**

```text
IMAGES (15):
  1-3: Hero product shots (different angles)
  4-6: Product in use (lifestyle)
  7-9: Before/after or transformation
  10-12: Social proof / team
  13-15: Seasonal / promotional

SHORT HEADLINES (5, 30 char):
  [Keyword] / [Benefit] / [Offer] / [Social Proof] / [CTA]

LONG HEADLINE (1, 90 char):
  Complete value proposition with benefit and differentiator

DESCRIPTIONS (5, 90 char):
  Core value prop / Social proof / Offer+urgency / Features / CTA+guarantee
```

**RDA Example — Online Courses:**

```text
Short: Learn [Skill] Online / Advance Your Career Fast / 50% Off This Week /
       Join 100K+ Students / Start Learning Today

Long:  Master In-Demand Skills With Expert-Led Courses. Flexible Learning for Busy Professionals.

D1: Expert-led courses in tech, business & creative fields. Learn at your pace with lifetime access.
D2: Trusted by 100,000+ professionals worldwide. 4.7-star average rating. Certificates included.
D3: Limited time: 50% off all courses. New content added weekly. Money-back guarantee.
D4: Video lessons, hands-on projects, quizzes & certificates. Mobile app available.
D5: Start your free 7-day trial today. No credit card required. Cancel anytime.
```

### Performance Max Asset Groups

Single campaign across all Google properties (Search, Display, YouTube, Gmail, Discover, Maps).

**Specs (per asset group):**

| Element | Dimensions / Limit | Max count |
|---------|-------------------|-----------|
| Landscape image (1.91:1) | 1200x628 (min 600x314) | 20 total |
| Square image (1:1) | 1200x1200 (min 300x300) | (included above) |
| Portrait image (4:5) | 960x1200 (min 480x600) | (included above) |
| Logos (1:1 + 4:1) | 1200x1200 / 1200x300 | 5 |
| Videos (YouTube) | 16:9, 9:16, 1:1; 10-30s recommended | 5 |
| Short headlines | 30 char | 3-5 (recommend 5) |
| Long headlines | 90 char | 1-5 (recommend 5) |
| Descriptions | 90 char | 2-5 (recommend 5) |
| Business name | 25 char | 1 |

File types: JPG/PNG, max 5120 KB. Max 100 asset groups per campaign.

**PMax Best Practices:**

1. **Maximize asset diversity** — fill all slots; assets perform differently per channel
2. **All three image ratios** — landscape, square, portrait; 15-20 images mixing product/lifestyle/promo
3. **Video is essential** — min 1, recommend 5; PMax-specific (not recycled); vertical for Shorts/Discover, horizontal for in-stream
4. **Headline/description strategy** — same as RSA: unique, standalone, keyword-rich, benefit-focused
5. **Asset group organization** — separate by product category, customer segment, or offer

**PMax Asset Formula:**

```text
IMAGES (20):
  Landscape (1.91:1) — 8: 3 hero, 3 lifestyle, 2 promo
  Square (1:1) — 8: 3 hero, 3 lifestyle, 2 promo
  Portrait (4:5) — 4: 2 hero, 2 lifestyle

VIDEOS (5):
  1 horizontal product showcase, 2 vertical short-form, 1 square social-style, 1 testimonial

SHORT HEADLINES (5, 30 char):
  [Keyword] / [Benefit] / [Offer] / [Differentiator] / [Social proof]

LONG HEADLINES (5, 90 char):
  Value prop / Benefit+specifics / Offer+urgency / Problem solved / Social proof+CTA

DESCRIPTIONS (5, 90 char):
  Core value / Social proof / Offer+urgency / Features+ease / Guarantee+CTA
```

**PMax Example — E-commerce (Running Shoes):**

```text
Short: Premium Running Shoes / Run Faster, Recover Quicker / 40% Off Select Styles /
       Award-Winning Cushioning / 50K+ 5-Star Reviews

Long:  Performance Running Shoes Engineered for Speed, Comfort & Durability
       Run Longer With Less Fatigue - Advanced Cushioning Technology
       Limited Time: 40% Off Premium Styles + Free Shipping
       Say Goodbye to Foot Pain - Revolutionary Comfort Design
       Trusted by 50,000+ Runners - 4.8★ Average Rating - Shop Now

D1: Premium running shoes with patented cushioning. Lightweight, durable, all distances.
D2: Trusted by professional athletes and weekend warriors. Over 50,000 five-star reviews.
D3: Flash sale: 40% off select styles. Free shipping & returns. Limited stock. Shop today.
D4: Responsive foam midsole, breathable mesh upper, carbon-fiber plate. Built to perform.
D5: 90-day comfort guarantee. If they don't feel amazing, send them back. No questions asked.
```

### YouTube Ads Creative

#### Skippable In-Stream Ads

- **Specs:** 16:9 recommended (vertical supported), 1080p+, min 12s, skip after 5s
- **Core principle:** First 5 seconds are everything — hook, brand reveal, core benefit, reason to stay

**In-Stream Structure:**

```text
0-5s  (PRE-SKIP):  Hook (pattern interrupt) + brand/product + core benefit
5-15s (EARLY):     Expand benefit, show product in action, build credibility
15-30s (MAIN):     Demonstrate value, provide proof, address objections
30-45s (CLOSE):    Testimonial/results, clear offer, strong CTA, brand reinforcement
```

**Key tactics:** Front-load (assume many skip). Fast cuts pre-skip, slow after. Reward non-skippers with deeper value. Test multiple 5s hooks with same body.

#### Bumper Ads (Non-Skippable, 6s)

- **Specs:** Exactly 6 seconds, 16:9 or 1:1, 1080p
- **Core principle:** One idea only — brand awareness or single benefit

```text
0-2s: Hook/Visual
2-4s: Product/Benefit
4-6s: Brand/CTA
```

**Use cases:** Brand awareness, event announcements, product launch teasers, frequency-capping longer ads, sequential messaging.

**Bumper Examples:**

```text
Product Launch:  [0-2s] New product reveal with motion → [2-4s] Name + key benefit → [4-6s] "Available Now" + logo
Brand Awareness: [0-2s] Visual of customer pain → [2-4s] Brand + tagline → [4-6s] Logo + domain
Event Promo:     [0-2s] Event visual/dates → [2-4s] Key speakers → [4-6s] "Register Now" + URL
```

#### YouTube Shorts Ads

- **Specs:** 9:16 vertical only, 1080x1920, up to 60s, sound on by default
- **Core principle:** Shorts-native, entertainment-first, creator-style content

```text
0-3s:   Hook (scroll-stopper — first frame critical)
3-15s:  Value/Entertainment
15-45s: Soft product integration
45-60s: Soft CTA
```

**Key tactics:** Fast cuts, trending audio, text overlays. Less "ad-like" than in-stream. Sound matters — trending music, sync visuals to beat. No skip button; hook prevents scroll.

### Google Display Network Best Practices

**Banner ad hierarchy:** Headline → Image → CTA → Body copy.

**Key principles:**

- CTA button = highest contrast element; use brand colors strategically
- Headline: ≤5 words; single CTA; minimal copy; clear value proposition
- Animation: first 3s matter most; end on CTA frame; 15-30s total; loop 2-3x then stop
- Readable across all sizes; test color variations

**Display campaign types:**

| Type | Characteristics |
|------|----------------|
| Standard Display | Uploaded images, full creative control, all sizes manual |
| Responsive Display | Upload assets, Google assembles; auto-sizing, less control |
| Gmail Sponsored Promotions | Collapsed inbox ad → expands to email-like experience; subject line critical |

---

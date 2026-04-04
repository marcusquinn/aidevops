<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Google Ads Creative

Google Ads matches intent (the search query), not interruption. Meta stops the scroll; Google answers the question.

### Responsive Search Ads (RSA)

Default search format. Provide up to 15 headlines + 4 descriptions; Google's ML tests combinations.

| Element | Count | Char limit | Display |
|---------|-------|-----------|---------|
| Headlines | 3-15 (recommend 15) | 30 | 2-3 shown |
| Descriptions | 2-4 (recommend 4) | 90 | 1-2 shown |
| Path fields | 2 | 15 each | `domain/path1/path2` |

**Pinning:** Pin to H1/H2/H3 or D1/D2 sparingly — reduces ML flexibility. Pin 2-3 options to same position.

**Ad Strength:** Aim for Good/Excellent. Factors: asset count, uniqueness, keyword inclusion.

**Dynamic insertion:** `{KeyWord:Default Text}`, `{IF(device=mobile):Mobile|Desktop}`, `{LOCATION(City)}`, `{COUNTDOWN(2027/12/31 23:59:59)}`

**Asset rules:** Fill all 15 headlines + 4 descriptions. Primary keyword in 2+ headlines. Each headline adds distinct value (no synonyms). Every asset standalone-readable in any combination. Mix CTAs (Buy/Get/Try/Start/Download), benefits/features/proof, and lengths (15-20 + 28-30 char).

**Headline formula (15):**

```text
H1-H3:  Keyword-Rich — [Primary Keyword] - [Differentiator]
H4-H6:  Benefit — [Benefit] in [Timeframe] / [Problem Solved] - [Outcome]
H7-H9:  Offer — [Discount]% Off Today / Free [Bonus] With Purchase
H10-H12: Proof — Trusted by [N]+ [Customers] / [Rating]★ on [Platform]
H13-H15: CTA — Shop [Category] Now / Get Your Free [Lead Magnet]
```

**Description formula (4, 90 char):**

```text
D1: Value prop + top 3 benefits + differentiation
D2: Social proof (customer count/rating) + CTA
D3: Specific offer + urgency + CTA
D4: Key features list + ease of use + support/guarantee
```

**RSA example — Project Management Software:**

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

**Optimization cycle:** Launch (days 1-14, no changes, ~3,000 impressions minimum) → Analyze (day 14+, Asset Report, identify "Low" performers) → Optimize (replace "Low" assets, test new angles, maintain 10+ headlines / 3+ descriptions).

### Responsive Display Ads (RDA)

Auto-adjusts across Google Display Network (3M+ sites/apps).

| Element | Dimensions / Limit | Required | Max |
|---------|-------------------|----------|-----|
| Landscape image (1.91:1) | 1200x628 (min 600x314) | Yes | 15 total |
| Square image (1:1) | 1200x1200 (min 300x300) | Yes | (incl.) |
| Square logo (1:1) | 1200x1200 | Yes | 5 |
| Landscape logo (4:1) | 1200x300 | No | (incl.) |
| Videos (YouTube only) | 16:9, 9:16, 1:1; ≤30s | No | 5 |
| Short headlines | 30 char | Yes | 5 |
| Long headline | 90 char | Yes | 1 |
| Descriptions | 90 char | Yes | 5 |
| Business name | 25 char | Yes | 1 |

File types: JPG/PNG/GIF (non-animated), max 5120 KB.

**Best practices:** Fill all slots (15 images, 5 logos, 5 headlines, 5 descriptions). High-res images, <20% text, product in context. Logos: transparent background, readable small, both ratios. Minimal text-in-image (Google may crop). Short headlines: punchy/benefit; long headline: full value prop with keyword. Each description: unique angle covering benefits, proof, urgency, features, CTA.

**Asset formula:**

```text
IMAGES (15):
  1-3: Hero product shots    4-6: Product in use (lifestyle)
  7-9: Before/after           10-12: Social proof / team
  13-15: Seasonal / promotional

SHORT HEADLINES (5, 30 char):
  [Keyword] / [Benefit] / [Offer] / [Social Proof] / [CTA]

LONG HEADLINE (1, 90 char):
  Complete value proposition with benefit and differentiator

DESCRIPTIONS (5, 90 char):
  Core value prop / Social proof / Offer+urgency / Features / CTA+guarantee
```

**RDA example — Online Courses:**

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

| Element | Dimensions / Limit | Max |
|---------|-------------------|-----|
| Landscape image (1.91:1) | 1200x628 (min 600x314) | 20 total |
| Square image (1:1) | 1200x1200 (min 300x300) | (incl.) |
| Portrait image (4:5) | 960x1200 (min 480x600) | (incl.) |
| Logos (1:1 + 4:1) | 1200x1200 / 1200x300 | 5 |
| Videos (YouTube) | 16:9, 9:16, 1:1; 10-30s recommended | 5 |
| Short headlines | 30 char | 3-5 (recommend 5) |
| Long headlines | 90 char | 1-5 (recommend 5) |
| Descriptions | 90 char | 2-5 (recommend 5) |
| Business name | 25 char | 1 |

File types: JPG/PNG, max 5120 KB. Max 100 asset groups per campaign.

**Best practices:** Fill all slots — assets perform differently per channel. All three image ratios (landscape, square, portrait); 15-20 images mixing product/lifestyle/promo. Video essential (min 1, recommend 5; PMax-specific, not recycled; vertical for Shorts/Discover, horizontal for in-stream). Headline/description strategy: same as RSA. Organize asset groups by product category, customer segment, or offer.

**Asset formula:**

```text
IMAGES (20):
  Landscape (1.91:1) — 8: 3 hero, 3 lifestyle, 2 promo
  Square (1:1) — 8: 3 hero, 3 lifestyle, 2 promo
  Portrait (4:5) — 4: 2 hero, 2 lifestyle

VIDEOS (5):
  1 horizontal showcase, 2 vertical short-form, 1 square social-style, 1 testimonial

SHORT HEADLINES (5, 30 char):
  [Keyword] / [Benefit] / [Offer] / [Differentiator] / [Social proof]

LONG HEADLINES (5, 90 char):
  Value prop / Benefit+specifics / Offer+urgency / Problem solved / Social proof+CTA

DESCRIPTIONS (5, 90 char):
  Core value / Social proof / Offer+urgency / Features+ease / Guarantee+CTA
```

**PMax example — E-commerce (Running Shoes):**

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

### YouTube Ads

#### Skippable In-Stream

Specs: 16:9 recommended (vertical supported), 1080p+, min 12s, skip after 5s. First 5 seconds are everything — hook, brand reveal, core benefit, reason to stay.

```text
0-5s  (PRE-SKIP):  Hook (pattern interrupt) + brand/product + core benefit
5-15s (EARLY):     Expand benefit, show product in action, build credibility
15-30s (MAIN):     Demonstrate value, provide proof, address objections
30-45s (CLOSE):    Testimonial/results, clear offer, strong CTA, brand reinforcement
```

**Tactics:** Front-load (assume many skip). Fast cuts pre-skip, slow after. Reward non-skippers with deeper value. Test multiple 5s hooks with same body.

#### Bumper Ads (Non-Skippable, 6s)

Specs: Exactly 6 seconds, 16:9 or 1:1, 1080p. One idea only — brand awareness or single benefit.

```text
0-2s: Hook/Visual    2-4s: Product/Benefit    4-6s: Brand/CTA
```

Use cases: Brand awareness, event announcements, product launch teasers, frequency-capping longer ads, sequential messaging.

```text
Product Launch:  [0-2s] New product reveal → [2-4s] Name + key benefit → [4-6s] "Available Now" + logo
Brand Awareness: [0-2s] Customer pain visual → [2-4s] Brand + tagline → [4-6s] Logo + domain
Event Promo:     [0-2s] Event visual/dates → [2-4s] Key speakers → [4-6s] "Register Now" + URL
```

#### YouTube Shorts Ads

Specs: 9:16 vertical only, 1080x1920, up to 60s, sound on by default. Shorts-native, entertainment-first, creator-style.

```text
0-3s:   Hook (scroll-stopper — first frame critical)
3-15s:  Value/Entertainment
15-45s: Soft product integration
45-60s: Soft CTA
```

**Tactics:** Fast cuts, trending audio, text overlays. Less "ad-like" than in-stream. Trending music, sync visuals to beat. No skip button; hook prevents scroll.

### Google Display Network

**Banner hierarchy:** Headline → Image → CTA → Body copy.

**Principles:** CTA button = highest contrast element. Headline ≤5 words, single CTA, minimal copy, clear value prop. Animation: first 3s matter most, end on CTA frame, 15-30s total, loop 2-3x then stop. Test across sizes and color variations.

| Type | Characteristics |
|------|----------------|
| Standard Display | Uploaded images, full creative control, all sizes manual |
| Responsive Display | Upload assets, Google assembles; auto-sizing, less control |
| Gmail Sponsored Promotions | Collapsed inbox ad → expands to email-like; subject line critical |

---

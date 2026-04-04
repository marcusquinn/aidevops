<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Types of Personalization

Dynamic content adapts per visitor based on attributes, behavior, or context — increasing relevance and conversion.

## 1. Geo-Based

Customize by visitor location (country, state, city): shipping messaging, currency display, local store/event references, language auto-detection.

**Implementation**: Client-side IP geolocation (ipapi.co, MaxMind GeoIP) → JS conditional rendering. Server-side (better for SEO): detect IP, render appropriate content. Edge: Cloudflare Workers for zero-latency. Platforms: AB Tasty, Optimizely, VWO.

**Benchmark**: Booking.com — 20-30% higher conversion from local currency + nearby properties + local payment methods.

## 2. Returning Visitor Optimization

| Visitor State | Content Strategy |
|---|---|
| First visit | Educational content, features overview, welcome messaging |
| Return visit | Case studies, pricing, direct CTAs, cart recovery |
| Known user | Personalized recommendations based on history |

**Implementation**: Cookie/localStorage flag on first visit. Vary headlines, content focus, and CTAs by visit count.

**Benchmark**: Amazon-style "Welcome back, [Name]" with personalized recommendations — 15-25% higher engagement from returning visitors.

## 3. Referral Source

| Source | Strategy |
|---|---|
| Search (intent-based) | Match headline to search query ("best CRM for real estate" → "The #1 CRM for Real Estate Agents") |
| Paid ad | Match headline to ad promise ("Your 50% Discount is Ready!") |
| Email campaign | Acknowledge source ("Thanks for clicking! Here's your exclusive offer...") |
| Competitor referrer | Comparison messaging ("Switching from [Competitor]?") |

**Implementation**: URL parameters (`?source=facebook-ad&campaign=50-off`) or `document.referrer` detection.

**Benchmark**: Shopify source-specific landing pages — 30-50% higher conversion vs generic.

## 4. Behavioral

| Trigger | Response |
|---|---|
| Viewed 5+ pages on topic | Exit popup with related lead magnet |
| 5+ minutes on site | Subscribe prompt |
| Scrolled to bottom | Related content recommendations |
| Clicked pricing 3x | Live chat offer for pricing questions |
| Cart near free-shipping threshold | "Add $X more for free shipping!" |

**Implementation**: Scroll tracking, time-based triggers (`setTimeout`), page-view counters, cart value monitoring.

**Benchmark**: Netflix — 80% of viewing from personalized recommendations based on watch/rate/search/list behavior.

## 5. Dynamic Headlines

Change headlines by visitor attributes: location, industry (from form/referrer), device type, or time of day.

**Combine with A/B testing**: price-focused variants for coupon-site traffic, social-proof variants for organic.

## 6. Smart CTAs

| Lifecycle Stage | CTA |
|---|---|
| Anonymous visitor | "Start Free Trial" |
| Known contact | "Continue Where You Left Off" |
| Active trial user | "Upgrade to Pro" |
| Paying customer | "Refer a Friend, Get $50" |

Also adapt by cart state (empty → "Start Shopping", items → "Checkout Now ($142)") and time sensitivity (during sale → urgency CTA, after sale → standard CTA).

**Benchmark**: HubSpot smart CTAs — 200%+ CTR increase vs static.

## 7. Recommendation Engines

| Type | Logic | Example |
|---|---|---|
| Collaborative filtering | "Users who liked X also liked Y" | Amazon: "Customers who bought this also bought..." |
| Content-based filtering | "Similar to items you liked" | Netflix: "More shows like Stranger Things" |
| Hybrid | Combination of both | Spotify Discover Weekly (2x engagement vs generic playlists) |

**Tools**: Amazon Personalize, Google Recommendations AI, Dynamic Yield, Nosto.

## 8. Segmented A/B Testing

Segment tests by user attributes instead of showing the same variants to all users.

**Example**: E-commerce returning vs first-time visitors:
- Returning: 12% uplift with "Continue shopping" (vs "Welcome back!")
- First-time: 34% uplift with "Get 10% off" (vs "Browse best sellers")
- Overall: 23% lift vs 8% from unsegmented test

**Why**: Mobile/desktop, new/returning, and source-based behaviors differ enough that aggregate tests mask segment-specific winners.

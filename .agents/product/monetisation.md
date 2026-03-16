---
description: Product monetisation - revenue models, paywalls, subscriptions, freemium, pricing strategy — applies to mobile apps, browser extensions, web apps, and SaaS
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

# Product Monetisation - Revenue Models and Implementation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Implement and optimise product revenue streams
- **Applies to**: Mobile apps, browser extensions, web apps, SaaS
- **Models**: Subscriptions, one-time purchases, freemium, ads, affiliate, funnel
- **Mobile subscriptions**: RevenueCat (cross-platform subscription management)
- **Web/extension payments**: Stripe

**Revenue model decision tree**:

```text
Product solves a daily recurring problem?
  -> Subscription (weekly/monthly/annual)

Product provides one-time value (tool, utility)?
  -> One-time purchase or lifetime unlock

Product has broad appeal but low willingness to pay?
  -> Freemium with premium tier, or ad-supported

Product drives users to another product/service?
  -> Free (sales funnel / audience builder)

Product can recommend relevant products?
  -> Affiliate links + optional premium tier
```

<!-- AI-CONTEXT-END -->

## Revenue Models

### Subscription

Best for products that solve recurring problems. Users pay weekly, monthly, or annually.

**Implementation by platform**:

| Platform | Tool | Notes |
|----------|------|-------|
| iOS + Android | RevenueCat | Cross-platform, handles App Store + Play Store |
| Web / SaaS | Stripe Billing | Flexible, developer-friendly |
| Browser extension | Stripe + license key | No native store payment API |

For RevenueCat mobile integration details, see `services/payments/revenuecat.md`.

### One-Time Purchase

Best for tools and utilities that provide permanent value.

- **Mobile**: In-app purchase via App Store / Play Store (RevenueCat manages)
- **Web**: Stripe one-time payment
- **Extension**: Stripe + license key validation

### Freemium

Core functionality free, premium features gated. Works when:

- Free tier provides genuine value (not a crippled demo)
- Premium tier feels like an upgrade, not a ransom
- Conversion rate target: 2-5% of free users

### Ad-Supported

- **AdMob** (Google): Banner, interstitial, rewarded ads (mobile)
- **Carbon Ads**: Developer-focused, non-intrusive (web)
- Best for: High-volume, low willingness-to-pay products
- Combine with premium tier to remove ads

### Affiliate

- Recommend relevant products/services within the product
- Use affiliate links for revenue share
- Must be transparent about affiliate relationships
- Works well for recommendation/review products

### Sales Funnel

- Product is free, drives users to paid service/product
- Product builds audience and trust
- Revenue comes from the external offering
- Works well for consultants, coaches, SaaS products

## Paywall Design

### Principles

- Show paywall at the moment of highest intent (after user tries a premium feature)
- Display clear value proposition (what they get, not what they pay)
- Offer 3 tiers: weekly (highest per-unit), monthly (default), annual (best value)
- Highlight the "best value" option visually
- Include free trial option (3 or 7 days)
- Show social proof (user count, ratings)
- "Restore Purchases" button must be accessible (mobile)

### Paywall Placement

| Trigger | Conversion Rate | Notes |
|---------|----------------|-------|
| After onboarding | Medium | User hasn't experienced value yet |
| Feature gate | High | User wants the feature NOW |
| Usage limit | High | User has experienced value, wants more |
| Settings/upgrade | Low | Only motivated users find it |
| Time-delayed | Medium | After N days of free use |

### Free Trial Strategy

- 3-day trial: Higher conversion, lower retention
- 7-day trial: Lower conversion, higher retention
- No trial: Highest friction, but attracts committed users
- Recommendation: 7-day trial for subscription products, no trial for one-time purchases

## Pricing Strategy

### Research-Based Pricing

1. Check competitor pricing in stores and directories
2. Survey target users on willingness to pay
3. Start with competitive pricing, adjust based on data
4. Annual plans should offer 15-40% discount vs monthly

### Common Price Points

| Model | Consumer | Prosumer | Business |
|-------|---------|----------|---------|
| Weekly | $2.99-$4.99 | $4.99-$9.99 | N/A |
| Monthly | $4.99-$9.99 | $9.99-$19.99 | $29-$99 |
| Annual | $29.99-$59.99 | $59.99-$149.99 | $199-$999 |
| Lifetime | $49.99-$99.99 | $99.99-$249.99 | N/A |

### A/B Testing

Test pricing and paywall variants using:

- RevenueCat Experiments (mobile)
- Superwall (mobile paywall A/B testing)
- Stripe + feature flags (web)

Test variables:

- Different price points
- Different paywall designs
- Different trial lengths
- Different feature gates

## Legal Requirements

- Clearly display subscription terms before purchase
- Show renewal price and frequency
- Provide easy cancellation instructions
- Include "Restore Purchases" for returning users (mobile)
- Privacy policy must cover payment data handling
- EULA required for subscription products
- GDPR/CCPA compliance for EU/California users

## Related

- `services/payments/revenuecat.md` - RevenueCat setup, SDK, entitlements (mobile)
- `services/payments/stripe.md` - Stripe payments (web, extensions, SaaS)
- `product/onboarding.md` - Paywall placement in onboarding
- `product/analytics.md` - Revenue analytics and optimisation
- `product/growth.md` - Acquisition to drive monetisation funnel

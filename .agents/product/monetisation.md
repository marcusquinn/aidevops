---
description: Product monetisation - revenue models, subscriptions, paywalls, ads, freemium for any app type
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
- **Models**: Subscriptions, one-time purchases, freemium, ads, affiliate, funnel
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps, SaaS

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

**Platform payment tools**:

| Platform | Primary Tool | Alternative |
|----------|-------------|-------------|
| Mobile (iOS + Android) | RevenueCat | Superwall (paywall A/B testing) |
| Browser extensions | Stripe, Chrome Web Store payments | LemonSqueezy, Gumroad |
| Desktop apps | Stripe, Paddle | LemonSqueezy, Gumroad |
| Web apps / SaaS | Stripe | Paddle, LemonSqueezy |

<!-- AI-CONTEXT-END -->

## Subscription Management

### RevenueCat (Mobile)

RevenueCat is the recommended subscription management platform for mobile apps. It handles:

- Cross-platform subscription state (iOS + Android)
- Receipt validation and entitlement management
- Analytics and cohort analysis
- A/B testing paywalls (via Superwall or RevenueCat Paywalls)
- Webhook integrations for backend sync

See `services/payments/revenuecat.md` for detailed setup and SDK integration.

### Stripe (Web, Desktop, Extensions)

Stripe is the recommended payment platform for non-mobile products:

- Subscription billing with Stripe Billing
- One-time payments with Checkout
- Customer portal for self-service management
- Webhook integrations for entitlement sync

See `services/payments/stripe.md` for detailed setup.

### Superwall (Paywall A/B Testing)

Superwall provides remote paywall configuration and A/B testing:

- Change paywall design without app updates
- Test different pricing, layouts, and copy
- Trigger paywalls based on user behaviour
- Works alongside RevenueCat or Stripe

See `services/payments/superwall.md` for setup.

## Entitlements Model

```text
Products (what users buy)     -> Entitlements (what users get access to)
├── Monthly ($4.99/mo)        -> "premium" entitlement
├── Annual ($39.99/yr)        -> "premium" entitlement
├── Lifetime ($99.99)         -> "premium" entitlement
└── Pro Add-on ($2.99/mo)     -> "pro" entitlement
```

This model is platform-agnostic — whether you use RevenueCat, Stripe, or another provider, the entitlement concept is the same: users buy products, products grant entitlements, features check entitlements.

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
| After onboarding (hard paywall) | Medium-high | User hasn't experienced value but onboarding built intent |
| Feature gate | High | User wants the feature NOW |
| Usage limit | High | User has experienced value, wants more |
| Settings/upgrade | Low | Only motivated users find it |
| Time-delayed | Medium | After N days of free use |

See `product/onboarding.md` for the hard paywall pattern and when to use it.

### Free Trial Strategy

- 3-day trial: Higher conversion, lower retention
- 7-day trial: Lower conversion, higher retention
- No trial: Highest friction, but attracts committed users
- Recommendation: 7-day trial for subscription products, no trial for one-time purchases

## Alternative Revenue Models

### Ad-Supported

- **AdMob** (Google): Banner, interstitial, rewarded ads (mobile)
- **Unity Ads**: Rewarded video (good for games)
- **Carbon Ads**: Developer/tech audience (web, extensions)
- Best for: High-volume, low willingness-to-pay products
- Combine with premium tier to remove ads

### Freemium

- Core functionality free, premium features gated
- Works well when free tier provides genuine value
- Premium tier should feel like an upgrade, not a ransom

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

## Pricing Strategy

### Research-Based Pricing

1. Check competitor pricing in relevant stores
2. Survey target users on willingness to pay
3. Start with competitive pricing, adjust based on data
4. Annual plans should offer 15-40% discount vs monthly

### Common Price Points

| Model | Typical Range |
|-------|--------------|
| Weekly | $2.99-$7.99 |
| Monthly | $4.99-$14.99 |
| Annual | $29.99-$79.99 |
| Lifetime | $49.99-$149.99 |
| One-time (extension/desktop) | $9.99-$49.99 |

### A/B Testing

Use RevenueCat Experiments, Superwall, or Stripe's test mode to test:

- Different price points
- Different paywall designs
- Different trial lengths
- Different feature gates

## The Recurring Revenue Mental Model

Think of products as digital properties and users as tenants:

- **Build once, sell forever** — unlike services, products don't require per-customer delivery
- **Subscription = recurring rent** — predictable monthly revenue that compounds
- **Churn = vacancy** — reducing churn is as important as acquiring new users
- **LTV > CAC** — lifetime value must exceed customer acquisition cost for sustainability

This mental model applies across all product types. A browser extension with 10,000 subscribers at $3/month generates $30k/month with near-zero marginal cost per user.

## Legal Requirements

- Clearly display subscription terms before purchase
- Show renewal price and frequency
- Provide easy cancellation instructions
- Include "Restore Purchases" for returning users (mobile)
- Privacy policy must cover payment data handling
- EULA required for subscription apps (mobile)
- Comply with platform-specific payment rules (Apple's 3.1.1, Google's billing policy)

## Related

- `services/payments/revenuecat.md` - RevenueCat setup (mobile)
- `services/payments/superwall.md` - Paywall A/B testing
- `services/payments/stripe.md` - Stripe payments (web, desktop, extensions)
- `product/onboarding.md` - Paywall placement in onboarding
- `product/analytics.md` - Revenue analytics and optimisation
- `product/growth.md` - User acquisition to feed the revenue funnel

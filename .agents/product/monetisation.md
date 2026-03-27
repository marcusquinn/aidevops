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
Daily recurring problem?          -> Subscription (weekly/monthly/annual)
One-time value (tool/utility)?    -> One-time purchase or lifetime unlock
Broad appeal, low willingness?    -> Freemium + premium tier, or ad-supported
Drives users to another product?  -> Free (sales funnel / audience builder)
Can recommend relevant products?  -> Affiliate links + optional premium tier
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

- **RevenueCat** (mobile): cross-platform subscription state, receipt validation, entitlements, A/B testing, webhooks. See `services/payments/revenuecat.md`.
- **Stripe** (web/desktop/extensions): subscription billing, one-time payments, customer portal, webhooks. See `services/payments/stripe.md`.
- **Superwall** (paywall A/B testing): remote paywall config, test pricing/layouts/copy without app updates, works alongside RevenueCat or Stripe. See `services/payments/superwall.md`.

## Entitlements Model

```text
Products (what users buy)     -> Entitlements (what users get access to)
├── Monthly ($4.99/mo)        -> "premium" entitlement
├── Annual ($39.99/yr)        -> "premium" entitlement
├── Lifetime ($99.99)         -> "premium" entitlement
└── Pro Add-on ($2.99/mo)     -> "pro" entitlement
```

Platform-agnostic: users buy products → products grant entitlements → features check entitlements.

## Paywall Design

**Principles**: Show at moment of highest intent (after user tries premium feature). Display value proposition (what they get, not what they pay). Offer 3 tiers: weekly (highest per-unit), monthly (default), annual (best value). Highlight best value. Include 3–7 day free trial. Show social proof. "Restore Purchases" button required on mobile.

**Placement**:

| Trigger | Conversion | Notes |
|---------|-----------|-------|
| After onboarding (hard paywall) | Medium-high | Intent built during onboarding |
| Feature gate | High | User wants the feature NOW |
| Usage limit | High | User has experienced value, wants more |
| Settings/upgrade | Low | Only motivated users find it |
| Time-delayed | Medium | After N days of free use |

See `product/onboarding.md` for the hard paywall pattern.

**Free trial**: 3-day → higher conversion, lower retention. 7-day → lower conversion, higher retention. Recommendation: 7-day for subscriptions, no trial for one-time purchases.

## Alternative Revenue Models

| Model | Best for | Notes |
|-------|---------|-------|
| Ad-supported (AdMob, Unity Ads, Carbon Ads) | High-volume, low willingness-to-pay | Combine with premium tier to remove ads |
| Freemium | Products with genuine free-tier value | Premium should feel like upgrade, not ransom |
| Affiliate | Recommendation/review products | Must disclose affiliate relationships |
| Sales funnel | Consultants, coaches, SaaS | Product is free; revenue from external offering |

## Pricing Strategy

1. Check competitor pricing in relevant stores
2. Survey target users on willingness to pay
3. Start competitive, adjust based on data; annual plans 15–40% off monthly

**Common price points**:

| Model | Typical Range |
|-------|--------------|
| Weekly | $2.99–$7.99 |
| Monthly | $4.99–$14.99 |
| Annual | $29.99–$79.99 |
| Lifetime | $49.99–$149.99 |
| One-time (extension/desktop) | $9.99–$49.99 |

A/B test price points, paywall designs, trial lengths, and feature gates via RevenueCat Experiments, Superwall, or Stripe test mode.

## Recurring Revenue Mental Model

- **Build once, sell forever** — no per-customer delivery cost
- **Subscription = recurring rent** — predictable revenue that compounds
- **Churn = vacancy** — reducing churn is as important as acquiring new users
- **LTV > CAC** — lifetime value must exceed acquisition cost

Example: 10,000 subscribers at $3/month = $30k/month with near-zero marginal cost.

## Legal Requirements

- Display subscription terms, renewal price, and frequency before purchase
- Provide easy cancellation instructions
- "Restore Purchases" button required (mobile)
- Privacy policy must cover payment data handling
- EULA required for subscription apps (mobile)
- Comply with Apple 3.1.1 and Google billing policy

## Related

- `services/payments/revenuecat.md` — RevenueCat setup (mobile)
- `services/payments/superwall.md` — Paywall A/B testing
- `services/payments/stripe.md` — Stripe payments (web, desktop, extensions)
- `product/onboarding.md` — Paywall placement in onboarding
- `product/analytics.md` — Revenue analytics and optimisation
- `product/growth.md` — User acquisition to feed the revenue funnel

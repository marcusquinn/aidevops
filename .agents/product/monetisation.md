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

# Product Monetisation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Implement and optimise product revenue streams
- **Models**: Subscriptions, one-time purchases, freemium, ads, affiliate, funnel
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps, SaaS
- **Core metric**: LTV > CAC

**Revenue model decision tree**:

```text
Daily recurring problem?           -> Subscription (weekly/monthly/annual)
One-time value (tool/utility)?     -> One-time purchase or lifetime unlock
Broad appeal, low willingness?     -> Freemium + premium tier, or ad-supported
Drives users to another offering?  -> Free (sales funnel / audience builder)
Can recommend relevant products?   -> Affiliate links + optional premium tier
```

<!-- AI-CONTEXT-END -->

## Payment Providers

| Platform | Primary | Alternative | Notes |
|----------|---------|-------------|-------|
| Mobile (iOS + Android) | RevenueCat | Superwall (paywall A/B) | Cross-platform state, receipt validation, entitlements. See `services/payments/revenuecat.md` |
| Browser extensions | Stripe | LemonSqueezy, Gumroad | See `services/payments/stripe.md` |
| Desktop apps | Stripe, Paddle | LemonSqueezy, Gumroad | |
| Web apps / SaaS | Stripe | Paddle, LemonSqueezy | |

Superwall: remote paywall config, price/layout/copy A/B testing (`services/payments/superwall.md`).

## Entitlements Model

Products → entitlements → feature gates (platform-agnostic):

```text
├── Monthly ($4.99/mo)        -> "premium" entitlement
├── Annual ($39.99/yr)        -> "premium" entitlement
├── Lifetime ($99.99)         -> "premium" entitlement
└── Pro Add-on ($2.99/mo)     -> "pro" entitlement
```

## Paywall Design

**Principles**:

- Show at moment of highest intent (after user tries a premium feature)
- Display value proposition, not price
- Offer 3 tiers: weekly (highest per-unit), monthly (default), annual (best value) — highlight "best value"
- Include free trial and social proof
- "Restore Purchases" must be accessible (mobile)

**Placement by conversion rate**:

| Trigger | Conversion | Notes |
|---------|-----------|-------|
| Feature gate | High | User wants the feature NOW |
| Usage limit | High | User has experienced value, wants more |
| After onboarding (hard paywall) | Medium-high | Onboarding built intent. See `product/onboarding.md` |
| Time-delayed | Medium | After N days of free use |
| Settings/upgrade | Low | Only motivated users find it |

**Free trial length**:

| Length | Conversion | Retention | Best for |
|--------|-----------|-----------|----------|
| 3-day | Higher | Lower | Quick-value products |
| 7-day | Lower | Higher | Subscriptions (recommended) |
| No trial | Lowest | Highest | One-time purchases |

**A/B testing**: RevenueCat Experiments, Superwall, or Stripe test mode for price points, paywall designs, trial lengths, and feature gates.

## Alternative Revenue Models

| Model | Best for | Notes |
|-------|---------|-------|
| **Ad-supported** | High-volume, low WTP | AdMob (mobile), Unity Ads (games), Carbon Ads (dev/tech). Combine with premium to remove ads |
| **Freemium** | Genuine free-tier value | Premium should feel like upgrade, not ransom |
| **Affiliate** | Recommendation/review products | Transparent disclosure required |
| **Sales funnel** | Consultants, coaches, SaaS | Product is free; revenue from external offering |

## Pricing Strategy

**Process**: Check competitor pricing -> survey target users on WTP -> start competitive, adjust on data -> annual plans: 15-40% discount vs monthly.

| Model | Typical Range |
|-------|--------------|
| Weekly | $2.99-$7.99 |
| Monthly | $4.99-$14.99 |
| Annual | $29.99-$79.99 |
| Lifetime | $49.99-$149.99 |
| One-time (extension/desktop) | $9.99-$49.99 |

## Legal Requirements

| Requirement | Applies to |
|-------------|-----------|
| Display subscription terms + renewal price/frequency before purchase | All |
| Provide easy cancellation instructions | All |
| "Restore Purchases" button | Mobile |
| Privacy policy covering payment data | All |
| EULA for subscription apps | Mobile |
| Platform payment rules (Apple 3.1.1, Google billing policy) | Mobile |

## Related

- `product/analytics.md` — Revenue analytics and optimisation
- `product/growth.md` — User acquisition to feed the revenue funnel

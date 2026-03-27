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
Product solves a daily recurring problem?      -> Subscription (weekly/monthly/annual)
Product provides one-time value (tool/utility)? -> One-time purchase or lifetime unlock
Broad appeal but low willingness to pay?        -> Freemium + premium tier, or ad-supported
Product drives users to another offering?       -> Free (sales funnel / audience builder)
Product can recommend relevant products?        -> Affiliate links + optional premium tier
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

| Provider | Use for | Details |
|----------|---------|---------|
| **RevenueCat** | Mobile (iOS + Android) | Cross-platform state, receipt validation, entitlements, A/B testing, webhooks. See `services/payments/revenuecat.md` |
| **Stripe** | Web, desktop, extensions | Billing, Checkout, customer portal, webhook entitlement sync. See `services/payments/stripe.md` |
| **Superwall** | Paywall A/B testing (any) | Remote paywall config, price/layout/copy testing, behaviour triggers. See `services/payments/superwall.md` |

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

**Principles:**
- Show at moment of highest intent (after user tries a premium feature)
- Display value proposition (what they get, not what they pay)
- Offer 3 tiers: weekly (highest per-unit), monthly (default), annual (best value)
- Highlight "best value" visually; include 3 or 7-day free trial; show social proof
- "Restore Purchases" button must be accessible (mobile)

**Placement by conversion rate:**

| Trigger | Conversion | Notes |
|---------|-----------|-------|
| Feature gate | High | User wants the feature NOW |
| Usage limit | High | User has experienced value, wants more |
| After onboarding (hard paywall) | Medium-high | Onboarding built intent |
| Time-delayed | Medium | After N days of free use |
| Settings/upgrade | Low | Only motivated users find it |

See `product/onboarding.md` for the hard paywall pattern.

**Free trial:**
- 3-day: higher conversion, lower retention
- 7-day: lower conversion, higher retention (recommended for subscriptions)
- No trial: highest friction, attracts committed users; recommended for one-time purchases

## Alternative Revenue Models

| Model | Best for | Notes |
|-------|---------|-------|
| **Ad-supported** | High-volume, low WTP | AdMob (mobile), Unity Ads (games), Carbon Ads (dev/tech web). Combine with premium tier to remove ads |
| **Freemium** | Products with genuine free-tier value | Premium should feel like upgrade, not ransom |
| **Affiliate** | Recommendation/review products | Transparent disclosure required; revenue share via affiliate links |
| **Sales funnel** | Consultants, coaches, SaaS | Product is free; revenue from external offering it drives users toward |

## Pricing Strategy

**Research process:**
1. Check competitor pricing in relevant stores
2. Survey target users on willingness to pay
3. Start competitive, adjust based on data
4. Annual plans: 15–40% discount vs monthly

**Common price points:**

| Model | Typical Range |
|-------|--------------|
| Weekly | $2.99–$7.99 |
| Monthly | $4.99–$14.99 |
| Annual | $29.99–$79.99 |
| Lifetime | $49.99–$149.99 |
| One-time (extension/desktop) | $9.99–$49.99 |

**A/B testing:** Use RevenueCat Experiments, Superwall, or Stripe test mode to test price points, paywall designs, trial lengths, and feature gates.

## Recurring Revenue Mental Model

- **Build once, sell forever** — unlike services, no per-customer delivery cost
- **Subscription = recurring rent** — predictable monthly revenue that compounds
- **Churn = vacancy** — reducing churn is as important as acquiring new users
- **LTV > CAC** — lifetime value must exceed customer acquisition cost

Example: 10,000 subscribers × $3/month = $30k/month with near-zero marginal cost per user.

## Legal Requirements

- Display subscription terms clearly before purchase
- Show renewal price and frequency
- Provide easy cancellation instructions
- Include "Restore Purchases" for returning users (mobile)
- Privacy policy must cover payment data handling
- EULA required for subscription apps (mobile)
- Comply with platform payment rules (Apple 3.1.1, Google billing policy)

## Related

- `services/payments/revenuecat.md` — RevenueCat setup (mobile)
- `services/payments/superwall.md` — Paywall A/B testing
- `services/payments/stripe.md` — Stripe payments (web, desktop, extensions)
- `product/onboarding.md` — Paywall placement in onboarding
- `product/analytics.md` — Revenue analytics and optimisation
- `product/growth.md` — User acquisition to feed the revenue funnel

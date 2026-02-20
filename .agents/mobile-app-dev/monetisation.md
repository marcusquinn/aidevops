---
description: Mobile app monetisation - RevenueCat, subscriptions, paywalls, ads, freemium, affiliate models
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

# App Monetisation - Revenue Models and Implementation

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Implement and optimise app revenue streams
- **Primary tool**: RevenueCat (cross-platform subscription management)
- **Docs**: Use Context7 MCP for latest RevenueCat documentation
- **Models**: Subscriptions, one-time purchases, freemium, ads, affiliate, funnel

**Shared with**: `browser-extension-dev.md` (same monetisation principles, different payment APIs)

**Revenue model decision tree**:

```text
App solves a daily recurring problem?
  -> Subscription (weekly/monthly/annual)

App provides one-time value (tool, utility)?
  -> One-time purchase or lifetime unlock

App has broad appeal but low willingness to pay?
  -> Freemium with premium tier, or ad-supported

App drives users to another product/service?
  -> Free (sales funnel / audience builder)

App can recommend relevant products?
  -> Affiliate links + optional premium tier
```

<!-- AI-CONTEXT-END -->

## RevenueCat Integration

RevenueCat is the recommended subscription management platform. It handles:

- Cross-platform subscription state (iOS + Android)
- Receipt validation and entitlement management
- Analytics and cohort analysis
- A/B testing paywalls (via Superwall or RevenueCat Paywalls)
- Webhook integrations for backend sync

### Setup Steps

1. **Create RevenueCat account**: https://app.revenuecat.com
2. **Create a project** in RevenueCat dashboard
3. **Configure App Store Connect** (iOS):
   - Create in-app purchase products
   - Generate App Store Connect API key for RevenueCat
   - Add shared secret for receipt validation
4. **Configure Google Play Console** (Android):
   - Create subscription products
   - Add service account credentials to RevenueCat
5. **Install SDK**:

```bash
# Expo
npx expo install react-native-purchases

# Swift (SPM)
# Add https://github.com/RevenueCat/purchases-ios.git
```

6. **Configure in app**:

```typescript
// Expo / React Native
import Purchases from 'react-native-purchases';

Purchases.configure({
  apiKey: Platform.OS === 'ios'
    ? 'appl_your_api_key'
    : 'goog_your_api_key',
});
```

### Entitlements Model

```text
Products (what users buy)     -> Entitlements (what users get access to)
├── Monthly ($4.99/mo)        -> "premium" entitlement
├── Annual ($39.99/yr)        -> "premium" entitlement
├── Lifetime ($99.99)         -> "premium" entitlement
└── Pro Add-on ($2.99/mo)     -> "pro" entitlement
```

### Checking Access

```typescript
// React Native
const customerInfo = await Purchases.getCustomerInfo();
const isPremium = customerInfo.entitlements.active['premium'] !== undefined;
```

```swift
// Swift
let customerInfo = try await Purchases.shared.customerInfo()
let isPremium = customerInfo.entitlements["premium"]?.isActive == true
```

## Paywall Design

### Principles

- Show paywall at the moment of highest intent (after user tries a premium feature)
- Display clear value proposition (what they get, not what they pay)
- Offer 3 tiers: weekly (highest per-unit), monthly (default), annual (best value)
- Highlight the "best value" option visually
- Include free trial option (3 or 7 days)
- Show social proof (user count, ratings)
- "Restore Purchases" button must be accessible

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
- Recommendation: 7-day trial for subscription apps, no trial for one-time purchases

## Alternative Revenue Models

### Ad-Supported

- **AdMob** (Google): Banner, interstitial, rewarded ads
- **Unity Ads**: Rewarded video (good for games)
- Best for: High-volume, low willingness-to-pay apps
- Combine with premium tier to remove ads

### Freemium

- Core functionality free, premium features gated
- Works well when free tier provides genuine value
- Premium tier should feel like an upgrade, not a ransom

### Affiliate

- Recommend relevant products/services within the app
- Use affiliate links for revenue share
- Must be transparent about affiliate relationships
- Works well for recommendation/review apps

### Sales Funnel

- App is free, drives users to paid service/product
- App builds audience and trust
- Revenue comes from the external offering
- Works well for consultants, coaches, SaaS products

## Pricing Strategy

### Research-Based Pricing

1. Check competitor pricing in app stores
2. Survey target users on willingness to pay
3. Start with competitive pricing, adjust based on data
4. Annual plans should offer 15-40% discount vs monthly

### Common Price Points

| Model | iOS | Android |
|-------|-----|---------|
| Weekly | $2.99-$7.99 | $2.99-$7.99 |
| Monthly | $4.99-$14.99 | $4.99-$14.99 |
| Annual | $29.99-$79.99 | $29.99-$79.99 |
| Lifetime | $49.99-$149.99 | $49.99-$149.99 |

### A/B Testing

Use RevenueCat Experiments or Superwall to test:

- Different price points
- Different paywall designs
- Different trial lengths
- Different feature gates

## Legal Requirements

- Clearly display subscription terms before purchase
- Show renewal price and frequency
- Provide easy cancellation instructions
- Include "Restore Purchases" for returning users
- Privacy policy must cover payment data handling
- EULA required for subscription apps

## Related

- `mobile-app-dev/publishing.md` - Store submission with payments
- `mobile-app-dev/onboarding.md` - Paywall placement in onboarding
- `mobile-app-dev/analytics.md` - Revenue analytics and optimisation

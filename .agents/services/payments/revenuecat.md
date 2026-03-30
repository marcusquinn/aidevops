---
description: RevenueCat - cross-platform in-app subscription and purchase management
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

# RevenueCat - In-App Subscriptions Made Easy

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: Use Context7 MCP for latest RevenueCat documentation
- **Dashboard**: https://app.revenuecat.com
- **SDKs**: `react-native-purchases` (Expo/RN), `purchases-ios` (Swift), `purchases-android` (Kotlin)
- **Pricing**: Free up to $2,500 MTR, then 1% of tracked revenue

| RevenueCat handles | You handle |
|---|---|
| Receipt validation (Apple, Google, Stripe, Amazon) | Product creation in App Store Connect / Play Console |
| Entitlement management | Paywall UI design and implementation |
| Subscription lifecycle (trials, renewals, cancellations, grace periods) | Feature gating logic in your app |
| Cross-platform subscription state sync | App Store / Play Store submission |
| Analytics (MRR, churn, LTV, cohorts, conversion) | |
| Experiments (A/B test pricing and paywalls) | |
| Integrations (webhooks, Amplitude, Mixpanel, Slack) | |

<!-- AI-CONTEXT-END -->

## Core Concepts

- **Products**: Platform-specific items (App Store Connect / Play Console) mapped to entitlements
- **Entitlements**: Platform-agnostic access levels — "premium" works regardless of purchase source
- **Offerings**: Package groups shown to users; swap via dashboard without app updates (A/B test pricing)

## Setup

1. **RevenueCat**: https://app.revenuecat.com → create project → add app (iOS/Android)
2. **iOS**: Create IAP products → generate API key → upload to RevenueCat → add shared secret
3. **Android**: Create subscriptions → service account (financial perms) → upload JSON → grant access
4. **Entitlements**: Create in dashboard (e.g., "premium") → map products → create offerings

### Install SDK

```bash
# Expo / React Native
npx expo install react-native-purchases
```

```typescript
import Purchases, { LOG_LEVEL } from 'react-native-purchases';
Purchases.setLogLevel(LOG_LEVEL.DEBUG); // Remove in production
await Purchases.configure({
  apiKey: Platform.OS === 'ios' ? 'appl_your_ios_api_key' : 'goog_your_android_api_key',
});
```

```swift
// Swift (SPM: https://github.com/RevenueCat/purchases-ios.git)
import RevenueCat
Purchases.logLevel = .debug // Remove in production
Purchases.configure(withAPIKey: "appl_your_ios_api_key")
```

## Common Operations

### Check Status / Display Offerings / Purchase / Restore

```typescript
// Check subscription status
const customerInfo = await Purchases.getCustomerInfo();
const isPremium = customerInfo.entitlements.active['premium'] !== undefined;
const willRenew = customerInfo.entitlements.active['premium']?.willRenew ?? false;
const expirationDate = customerInfo.entitlements.active['premium']?.expirationDate;
// Swift: let info = try await Purchases.shared.customerInfo()
//        let isPremium = info.entitlements["premium"]?.isActive == true

// Display offerings (paywall)
const offerings = await Purchases.getOfferings();
const current = offerings.current;
if (current) {
  console.log(current.monthly?.product.priceString);  // "$4.99"
  console.log(current.annual?.product.priceString);   // "$39.99"
}

// Make a purchase
try {
  const { customerInfo } = await Purchases.purchasePackage(selectedPackage);
  if (customerInfo.entitlements.active['premium']) { /* unlock */ }
} catch (e) {
  if (!e.userCancelled) { /* handle error */ }
}
// Swift: let (_, info, _) = try await Purchases.shared.purchase(package: pkg)
//        if info.entitlements["premium"]?.isActive == true { /* unlock */ }

// Restore — required by App Store guidelines
const restored = await Purchases.restorePurchases();
const restoredPremium = restored.entitlements.active['premium'] !== undefined;

// Cross-platform sync — call after auth events
await Purchases.logIn(userId);   // After login
await Purchases.logOut();        // After logout
```

## RevenueCat Paywalls (Optional)

Server-configurable paywalls — update design without app releases:

```typescript
import RevenueCatUI from 'react-native-purchases-ui';
<RevenueCatUI.Paywall
  onPurchaseCompleted={({ customerInfo }) => { /* handle */ }}
  onRestoreCompleted={({ customerInfo }) => { /* handle */ }}
/>
```

## Webhooks

Configure in dashboard to sync events with your backend:

| Event | When |
|-------|------|
| `INITIAL_PURCHASE` | First purchase |
| `RENEWAL` | Renewed |
| `CANCELLATION` | Cancelled (active until period end) |
| `EXPIRATION` | Expired |
| `BILLING_ISSUE` | Payment failed |
| `PRODUCT_CHANGE` | Changed tier |

## Testing & Best Practices

**Sandbox**: iOS — sandbox Apple ID in App Store Connect. Android — license testing in Play Console. Dashboard shows sandbox vs production.

**Debug**: `Purchases.setLogLevel(LOG_LEVEL.DEBUG)` → inspect `getCustomerInfo()`.

**Rules**:

- Never cache entitlements locally — always call `getCustomerInfo()`
- Handle offline gracefully — SDK caches last known state
- Use offerings, not hardcoded product IDs — enables remote config
- Identify users after login for cross-device sync
- Monitor dashboard for billing issues and involuntary churn

## Related

- `product/monetisation.md` - Revenue model strategy and paywall design
- `services/payments/superwall.md` - Advanced paywall A/B testing
- `services/payments/stripe.md` - Web payment processing
- `tools/mobile/app-dev-publishing.md` - App Store submission with payments

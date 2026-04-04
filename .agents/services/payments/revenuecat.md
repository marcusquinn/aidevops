---
description: RevenueCat - cross-platform in-app subscription and purchase management
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# RevenueCat

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Docs**: Use Context7 MCP for latest RevenueCat documentation
- **Dashboard**: https://app.revenuecat.com
- **SDKs**: `react-native-purchases` (Expo/RN), `purchases-ios` (Swift), `purchases-android` (Kotlin)
- **Pricing**: Free up to $2,500 MTR, then 1% of tracked revenue
- **Products**: Platform-specific items mapped to **Entitlements** (platform-agnostic access levels, e.g. "premium")
- **Offerings**: Package groups shown to users; swap via dashboard without app updates (A/B test pricing)

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

## Setup

1. https://app.revenuecat.com → create project → add app (iOS/Android)
2. **iOS**: Create IAP products → generate API key → upload to RevenueCat → add shared secret
3. **Android**: Create subscriptions → service account (financial perms) → upload JSON → grant access
4. **Entitlements**: Create in dashboard (e.g., "premium") → map products → create offerings

```bash
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

```typescript
// Check entitlement
const customerInfo = await Purchases.getCustomerInfo();
const isPremium = customerInfo.entitlements.active['premium'] !== undefined;
// .willRenew — check renewal status; Swift: info.entitlements["premium"]?.isActive == true

// Display offerings
const offerings = await Purchases.getOfferings();
const current = offerings.current; // current.monthly?.product.priceString

// Purchase
try {
  const { customerInfo } = await Purchases.purchasePackage(selectedPackage);
  if (customerInfo.entitlements.active['premium']) { /* unlock */ }
} catch (e) {
  if (!e.userCancelled) { /* handle error */ }
}
// Swift: let (_, info, _) = try await Purchases.shared.purchase(package: pkg)

// Restore (required by App Store guidelines)
await Purchases.restorePurchases();

// Identity sync — call after auth events
await Purchases.logIn(userId);
await Purchases.logOut();
```

## Paywalls

Server-configurable — update without app releases:

```typescript
import RevenueCatUI from 'react-native-purchases-ui';
<RevenueCatUI.Paywall
  onPurchaseCompleted={({ customerInfo }) => { /* handle */ }}
  onRestoreCompleted={({ customerInfo }) => { /* handle */ }}
/>
```

## Webhooks

| Event | When |
|-------|------|
| `INITIAL_PURCHASE` | First purchase |
| `RENEWAL` | Renewed |
| `CANCELLATION` | Cancelled (active until period end) |
| `EXPIRATION` | Expired |
| `BILLING_ISSUE` | Payment failed |
| `PRODUCT_CHANGE` | Changed tier |

## Testing & Best Practices

**Sandbox**: iOS — sandbox Apple ID in App Store Connect. Android — license testing in Play Console.
**Debug**: `Purchases.setLogLevel(LOG_LEVEL.DEBUG)` → inspect `getCustomerInfo()`.

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

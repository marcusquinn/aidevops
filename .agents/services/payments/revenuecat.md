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

- **Purpose**: Cross-platform subscription management for iOS, Android, and web
- **Docs**: Use Context7 MCP for latest RevenueCat documentation
- **Dashboard**: https://app.revenuecat.com
- **SDKs**: `react-native-purchases` (Expo/RN), `purchases-ios` (Swift), `purchases-android` (Kotlin)
- **Pricing**: Free up to $2,500 MTR, then 1% of tracked revenue

**What RevenueCat handles**:

- Receipt validation (Apple, Google, Stripe, Amazon)
- Entitlement management (what users have access to)
- Subscription lifecycle (trials, renewals, cancellations, grace periods)
- Cross-platform subscription state sync
- Analytics (MRR, churn, LTV, cohorts, conversion)
- Experiments (A/B test pricing and paywalls)
- Integrations (webhooks, Amplitude, Mixpanel, Slack, etc.)

**What you still handle**:

- Product creation in App Store Connect / Google Play Console
- Paywall UI design and implementation
- Feature gating logic in your app
- App Store / Play Store submission

<!-- AI-CONTEXT-END -->

## Core Concepts

### Products, Entitlements, and Offerings

```text
Products (platform-specific)     Entitlements (what users unlock)
├── monthly_sub (App Store)  ──> "premium"
├── monthly_sub (Play Store) ──> "premium"
├── annual_sub (App Store)   ──> "premium"
├── annual_sub (Play Store)  ──> "premium"
└── lifetime (App Store)     ──> "premium"

Offerings (what users see)
├── Default Offering
│   ├── Monthly Package  -> monthly_sub product
│   ├── Annual Package   -> annual_sub product
│   └── Lifetime Package -> lifetime product
└── Experiment Offering (A/B test)
    ├── Monthly Package  -> monthly_sub_v2 product
    └── Annual Package   -> annual_sub_v2 product
```

**Products**: Platform-specific items (created in App Store Connect / Play Store Console).

**Entitlements**: Platform-agnostic access levels. A user with "premium" entitlement has access regardless of which product they purchased or which platform they're on.

**Offerings**: Groups of packages shown to users. Use offerings to A/B test different product combinations without app updates.

## Setup

### 1. Create RevenueCat Project

1. Sign up at https://app.revenuecat.com
2. Create a new project
3. Add your app (iOS and/or Android)

### 2. Configure App Store Connect (iOS)

1. Create in-app purchase products in App Store Connect
2. Generate an App Store Connect API key (In-App Purchase key type)
3. Upload the key to RevenueCat dashboard
4. Add your App Store Connect shared secret

### 3. Configure Google Play Console (Android)

1. Create subscription products in Google Play Console
2. Create a service account with financial permissions
3. Upload service account JSON to RevenueCat dashboard
4. Grant the service account access in Play Console

### 4. Configure Entitlements

1. In RevenueCat dashboard, create entitlements (e.g., "premium", "pro")
2. Map products to entitlements
3. Create offerings with packages

### 5. Install SDK

**Expo / React Native**:

```bash
npx expo install react-native-purchases
```

```typescript
import Purchases, { LOG_LEVEL } from 'react-native-purchases';

// Configure on app start
Purchases.setLogLevel(LOG_LEVEL.DEBUG); // Remove in production
await Purchases.configure({
  apiKey: Platform.OS === 'ios'
    ? 'appl_your_ios_api_key'
    : 'goog_your_android_api_key',
});
```

**Swift**:

Add via SPM: `https://github.com/RevenueCat/purchases-ios.git`

```swift
import RevenueCat

// Configure on app launch
Purchases.logLevel = .debug // Remove in production
Purchases.configure(withAPIKey: "appl_your_ios_api_key")
```

## Common Operations

### Check Subscription Status

```typescript
// React Native
const customerInfo = await Purchases.getCustomerInfo();
const isPremium = customerInfo.entitlements.active['premium'] !== undefined;
const willRenew = customerInfo.entitlements.active['premium']?.willRenew ?? false;
const expirationDate = customerInfo.entitlements.active['premium']?.expirationDate;
```

```swift
// Swift
let customerInfo = try await Purchases.shared.customerInfo()
let isPremium = customerInfo.entitlements["premium"]?.isActive == true
```

### Display Offerings (Paywall)

```typescript
// React Native
const offerings = await Purchases.getOfferings();
const currentOffering = offerings.current;

if (currentOffering) {
  const monthly = currentOffering.monthly;    // Package
  const annual = currentOffering.annual;      // Package
  const lifetime = currentOffering.lifetime;  // Package

  // Display prices
  console.log(monthly?.product.priceString);  // "$4.99"
  console.log(annual?.product.priceString);   // "$39.99"
}
```

### Make a Purchase

```typescript
// React Native
try {
  const { customerInfo } = await Purchases.purchasePackage(selectedPackage);
  if (customerInfo.entitlements.active['premium']) {
    // Unlock premium features
  }
} catch (e) {
  if (e.userCancelled) {
    // User cancelled, don't show error
  } else {
    // Handle error
  }
}
```

```swift
// Swift
do {
  let (_, customerInfo, _) = try await Purchases.shared.purchase(package: package)
  if customerInfo.entitlements["premium"]?.isActive == true {
    // Unlock premium features
  }
} catch {
  // Handle error
}
```

### Restore Purchases

```typescript
// React Native — required by App Store guidelines
const customerInfo = await Purchases.restorePurchases();
const isPremium = customerInfo.entitlements.active['premium'] !== undefined;
```

### Identify Users (for cross-platform sync)

```typescript
// After user logs in
await Purchases.logIn(userId);

// After user logs out
await Purchases.logOut();
```

## RevenueCat Paywalls (Optional)

RevenueCat offers server-side configurable paywalls (no app update needed to change design):

```typescript
// React Native
import RevenueCatUI from 'react-native-purchases-ui';

// Present paywall
<RevenueCatUI.Paywall
  onPurchaseCompleted={({ customerInfo }) => {
    // Handle purchase
  }}
  onRestoreCompleted={({ customerInfo }) => {
    // Handle restore
  }}
/>
```

## Webhooks

Configure webhooks in RevenueCat dashboard to sync subscription events with your backend:

| Event | When |
|-------|------|
| `INITIAL_PURCHASE` | First subscription purchase |
| `RENEWAL` | Subscription renewed |
| `CANCELLATION` | Subscription cancelled (still active until period end) |
| `EXPIRATION` | Subscription expired |
| `BILLING_ISSUE` | Payment failed |
| `PRODUCT_CHANGE` | User changed subscription tier |

## Testing

### Sandbox Testing

- **iOS**: Use sandbox Apple ID in App Store Connect
- **Android**: Use license testing in Google Play Console
- **RevenueCat**: Dashboard shows sandbox vs production transactions

### Debugging

```typescript
// Enable debug logs
Purchases.setLogLevel(LOG_LEVEL.DEBUG);

// Check current customer info
const info = await Purchases.getCustomerInfo();
console.log(JSON.stringify(info, null, 2));
```

## Best Practices

- **Never cache entitlements locally** — always check `getCustomerInfo()` for current state
- **Handle offline gracefully** — RevenueCat SDK caches last known state
- **Use offerings, not hardcoded product IDs** — enables remote configuration
- **Identify users** after login for cross-device sync
- **Test in sandbox** before going live
- **Monitor dashboard** for billing issues and involuntary churn

## Related

- `mobile-app-dev/monetisation.md` - Revenue model strategy and paywall design
- `services/payments/superwall.md` - Advanced paywall A/B testing
- `services/payments/stripe.md` - Web payment processing
- `mobile-app-dev/publishing.md` - App Store submission with payments

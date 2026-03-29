---
description: Superwall - advanced paywall A/B testing and remote configuration for mobile apps
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

# Superwall - Paywall Experimentation Platform

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: A/B test paywalls, remotely configure pricing and design without app updates
- **Docs**: Use Context7 MCP for latest Superwall documentation
- **Dashboard**: https://superwall.com/dashboard
- **SDKs**: `SuperwallKit` (Swift), `@superwall/react-native-superwall` (React Native)
- **Best for**: Apps with >$100K MRR looking to optimise conversion

**Superwall vs RevenueCat Paywalls**:

| Feature | Superwall | RevenueCat Paywalls |
|---------|-----------|-------------------|
| Paywall A/B testing | Advanced (multi-variant, holdout groups) | Basic |
| Remote paywall design | Full visual editor | Template-based |
| Analytics depth | Deep funnel analysis | Basic conversion |
| Pricing | Premium | Included with RevenueCat |
| Best for | High-revenue apps optimising conversion | Apps getting started with paywalls |

**Superwall works alongside RevenueCat** — Superwall handles paywall presentation and experimentation, RevenueCat handles subscription management and receipt validation.

<!-- AI-CONTEXT-END -->

## Core Concepts

- **Paywalls**: Configured remotely in the dashboard — design, products, trials, copy, and layout without app updates.
- **Placements**: Code hooks where paywalls can appear. The callback runs when the user has access (purchased or in holdout).
- **Campaigns**: Connect placements to paywalls with targeting rules, A/B variants, and holdout groups.

```swift
// Swift — register a placement
Superwall.shared.register(placement: "feature_gate") {
  unlockFeature() // runs if user has access
}
```

```typescript
// React Native — register a placement
Superwall.shared.register('feature_gate', () => {
  unlockFeature();
});
```

## Setup

### 1. Create Account

Sign up at https://superwall.com and create an app.

### 2. Install SDK

**Swift** — add via SPM: `https://github.com/superwall/Superwall-iOS.git`

```swift
import SuperwallKit

Superwall.configure(apiKey: "your_api_key")
```

**React Native**:

```bash
npm install @superwall/react-native-superwall
```

```typescript
import Superwall from '@superwall/react-native-superwall';

Superwall.configure('your_api_key');
```

### 3. Configure with RevenueCat

```swift
import SuperwallKit
import RevenueCat

let purchaseController = RCPurchaseController()
Superwall.configure(
  apiKey: "your_superwall_key",
  purchaseController: purchaseController
)
```

### 4. Register Placements

```swift
Superwall.shared.register(placement: "onboarding_complete")
Superwall.shared.register(placement: "premium_feature_tap")
Superwall.shared.register(placement: "settings_upgrade")
```

### 5. Configure in Dashboard

1. Create paywalls in the visual editor
2. Create campaigns linking placements to paywalls
3. Set up A/B test variants and targeting rules
4. Launch experiment

## Experimentation

Test paywall designs, pricing emphasis, trial lengths, and feature comparisons. Use holdout groups to measure paywall impact on retention.

### Key Metrics

| Metric | What It Tells You |
|--------|-------------------|
| Paywall view rate | How often users see the paywall |
| Conversion rate | % of paywall views that convert to purchase |
| Revenue per user | Average revenue generated per user |
| Trial start rate | % of users starting free trials |
| Trial-to-paid rate | % of trial users converting to paid |

## Related

- `services/payments/revenuecat.md` - Subscription management (use alongside Superwall)
- `product/monetisation.md` - Revenue model strategy
- `product/onboarding.md` - Paywall placement in user flows

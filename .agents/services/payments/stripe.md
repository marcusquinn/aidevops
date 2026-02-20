---
description: Stripe - payment processing for web apps, SaaS, and browser extensions
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

# Stripe - Payment Processing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Payment processing for web apps, SaaS, and browser extensions
- **Docs**: Use Context7 MCP for latest Stripe documentation
- **Dashboard**: https://dashboard.stripe.com
- **SDKs**: `stripe` (Node.js), `@stripe/stripe-js` (browser), `@stripe/react-stripe-js` (React)
- **Pricing**: 2.9% + 30c per transaction (US), varies by country

**When to use Stripe vs RevenueCat**:

| Use Case | Recommendation |
|----------|---------------|
| Mobile app subscriptions (iOS/Android) | RevenueCat (handles App Store/Play Store) |
| Web app subscriptions | Stripe |
| Browser extension premium | Stripe |
| One-time web payments | Stripe |
| SaaS billing | Stripe |
| Marketplace payments | Stripe Connect |

<!-- AI-CONTEXT-END -->

## Core Concepts

### Products and Prices

```text
Product (what you sell)
├── Price: $9.99/month (recurring)
├── Price: $99/year (recurring)
└── Price: $199 one-time (lifetime)
```

Create products in Stripe Dashboard or via API.

### Payment Methods

- **Checkout Sessions**: Stripe-hosted payment page (recommended for simplicity)
- **Payment Intents**: Custom payment flow with Stripe Elements
- **Customer Portal**: Stripe-hosted subscription management

### Subscription Lifecycle

```text
Created -> Trialing -> Active -> Past Due -> Canceled -> Expired
                                    |
                                    v
                              Unpaid (after retries)
```

## Setup

### 1. Install

```bash
# Server
npm install stripe

# Client (React)
npm install @stripe/stripe-js @stripe/react-stripe-js
```

### 2. Configure

```typescript
// Server
import Stripe from 'stripe';
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

// Client
import { loadStripe } from '@stripe/stripe-js';
const stripePromise = loadStripe(process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY);
```

### 3. Create Checkout Session (Server)

```typescript
const session = await stripe.checkout.sessions.create({
  mode: 'subscription', // or 'payment' for one-time
  line_items: [
    {
      price: 'price_xxx', // Price ID from Stripe Dashboard
      quantity: 1,
    },
  ],
  success_url: 'https://example.com/success?session_id={CHECKOUT_SESSION_ID}',
  cancel_url: 'https://example.com/cancel',
  customer_email: user.email,
});

// Redirect to session.url
```

### 4. Handle Webhooks (Server)

```typescript
// Verify webhook signature
const event = stripe.webhooks.constructEvent(
  body,
  signature,
  process.env.STRIPE_WEBHOOK_SECRET,
);

switch (event.type) {
  case 'checkout.session.completed':
    // Provision access
    break;
  case 'customer.subscription.updated':
    // Update subscription status
    break;
  case 'customer.subscription.deleted':
    // Revoke access
    break;
  case 'invoice.payment_failed':
    // Handle failed payment
    break;
}
```

## Customer Portal

Let users manage their own subscriptions:

```typescript
const portalSession = await stripe.billingPortal.sessions.create({
  customer: customerId,
  return_url: 'https://example.com/account',
});

// Redirect to portalSession.url
```

## Browser Extension Payments

For premium browser extensions, use Stripe with a license key system:

1. User purchases via Stripe Checkout on your website
2. Webhook generates a license key and emails it
3. User enters license key in extension options page
4. Extension validates key against your API

```typescript
// Extension options page
const validateLicense = async (key: string) => {
  const response = await fetch('https://api.example.com/validate', {
    method: 'POST',
    body: JSON.stringify({ licenseKey: key }),
  });
  const { valid, entitlements } = await response.json();
  if (valid) {
    await chrome.storage.sync.set({ license: key, entitlements });
  }
  return valid;
};
```

## Testing

- Use test mode keys (prefix `sk_test_` and `pk_test_`)
- Test card numbers: `4242424242424242` (success), `4000000000000002` (decline)
- Use Stripe CLI for local webhook testing: `stripe listen --forward-to localhost:3000/api/webhooks`
- Test subscription lifecycle with test clocks

## Security

- **Never expose secret key** in client-side code
- **Always verify webhooks** with signature checking
- **Use Stripe Checkout** or Elements — never handle raw card numbers
- **Store customer IDs**, not payment details, in your database
- Store Stripe keys via `aidevops secret set STRIPE_SECRET_KEY`

## Related

- `services/payments/revenuecat.md` - Mobile app subscriptions
- `services/payments/superwall.md` - Paywall A/B testing
- `mobile-app-dev/monetisation.md` - Revenue model strategy
- `browser-extension-dev/publishing.md` - Extension monetisation
- `tools/api/hono.md` - API framework for webhook handlers

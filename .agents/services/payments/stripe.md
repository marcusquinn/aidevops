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

- **Docs**: Context7 MCP for latest Stripe docs
- **Dashboard**: https://dashboard.stripe.com
- **SDKs**: `stripe` (Node.js), `@stripe/stripe-js` (browser), `@stripe/react-stripe-js` (React)
- **Pricing**: 2.9% + 30¢/transaction (US)

**Stripe vs RevenueCat**:

| Use Case | Use |
|----------|-----|
| Mobile subscriptions (iOS/Android) | RevenueCat |
| Web/SaaS subscriptions | Stripe |
| Browser extension premium | Stripe |
| One-time web payments | Stripe |
| Marketplace payments | Stripe Connect |

<!-- AI-CONTEXT-END -->

## Core Concepts

**Payment methods**: Checkout Sessions (hosted, recommended) · Payment Intents (custom Elements) · Customer Portal (hosted subscription management)

**Subscription lifecycle**: `Created → Trialing → Active → Past Due → Unpaid (after retries) → Canceled → Expired`

**Products and prices**: One product, multiple prices (e.g. monthly/annual/lifetime). Create in Dashboard or API.

## Setup

```bash
npm install stripe                                    # server
npm install @stripe/stripe-js @stripe/react-stripe-js # client (React)
```

```typescript
// Server
import Stripe from 'stripe';
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

// Client
import { loadStripe } from '@stripe/stripe-js';
const stripePromise = loadStripe(process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY);
```

**Create Checkout Session (server)**:

```typescript
const session = await stripe.checkout.sessions.create({
  mode: 'subscription', // or 'payment' for one-time
  line_items: [{ price: 'price_xxx', quantity: 1 }],
  success_url: 'https://example.com/success?session_id={CHECKOUT_SESSION_ID}',
  cancel_url: 'https://example.com/cancel',
  customer_email: user.email,
});
// Redirect to session.url
```

**Handle Webhooks (server)**:

```typescript
const event = stripe.webhooks.constructEvent(body, signature, process.env.STRIPE_WEBHOOK_SECRET);

switch (event.type) {
  case 'checkout.session.completed':    // Provision access
  case 'customer.subscription.updated': // Update subscription status
  case 'customer.subscription.deleted': // Revoke access
  case 'invoice.payment_failed':        // Handle failed payment
}
```

## Customer Portal

```typescript
const portalSession = await stripe.billingPortal.sessions.create({
  customer: customerId,
  return_url: 'https://example.com/account',
});
// Redirect to portalSession.url
```

## Browser Extension Payments

License key flow: user purchases via Checkout → webhook generates + emails license key → user enters key in extension options → extension validates against your API.

```typescript
// Extension options page
const validateLicense = async (key: string) => {
  const response = await fetch('https://api.example.com/validate', {
    method: 'POST',
    body: JSON.stringify({ licenseKey: key }),
  });
  const { valid, entitlements } = await response.json();
  if (valid) await chrome.storage.sync.set({ license: key, entitlements });
  return valid;
};
```

## Testing

- Test keys: `sk_test_` / `pk_test_` prefix
- Test cards: `4242424242424242` (success), `4000000000000002` (decline)
- Local webhooks: `stripe listen --forward-to localhost:3000/api/webhooks`
- Subscription lifecycle: use test clocks

## Security

- **Never expose secret key** client-side
- **Always verify webhooks** with signature checking
- **Use Checkout or Elements** — never handle raw card numbers
- **Store customer IDs**, not payment details
- Store keys: `aidevops secret set STRIPE_SECRET_KEY`

## Related

- `services/payments/revenuecat.md` - Mobile app subscriptions
- `services/payments/superwall.md` - Paywall A/B testing
- `product/monetisation.md` - Revenue model strategy
- `tools/browser/extension-dev/publishing.md` - Extension monetisation
- `tools/api/hono.md` - API framework for webhook handlers

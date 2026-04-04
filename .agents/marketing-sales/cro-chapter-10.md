<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Chapter 10: Checkout Flow Optimization - Deep Dive

Average cart abandonment is ~70%. Every friction point costs real revenue.

### Checkout Flow Structure

Streamline to 3 steps: (1) Email + Shipping Address, (2) Shipping Method + Payment, (3) Order Confirmation.

**Guest checkout**: 35% of abandonment is forced account creation (Baymard). Guest checkout yields 20-45% higher conversion. Default to guest; offer optional account post-purchase.

**Layout**: Accordion checkout recommended — single page, progressive disclosure, shows progress. Field count guide: <7 fields → one-page; 8-15 → test both; >15 or mobile-first → multi-step.

### Progress Indicators

Show "Cart" as completed first step (Endowed Progress Effect: 82% higher completion, Nunes & Dreze 2006). Options: step counter, step names, progress bar, or checked steps — all valid; choose by context.

### Form Field Optimization

Minimum: Email, Shipping Address, Payment. Phone optional (explain why if required; optional phone +5-10% conversion). Company name conditional on "business purchase" checkbox. Address Line 2 never required.

### Shipping and Payment

**Shipping**: Surprise costs are the #1 abandonment reason (Baymard: 50%). Show all options with prices upfront. Pre-select most popular. Decoy pricing works: mid-tier close to premium makes premium seem smart.

**Payment**: Display logos prominently. Express checkout (Apple Pay, Google Pay, PayPal) at top, card/BNPL below. BNPL (Affirm, Afterpay, Klarna): +30-50% AOV, +20-30% conversion on orders $100+. Digital wallets reduce checkout from 2-3 min to 10-20 sec. Show BNPL installment breakdown ("4 × $24.99 - no interest").

### Security and Trust Signals

| Signal | Placement |
|--------|-----------|
| SSL lock + "Secure Checkout" | Page header |
| Security badges (Norton, McAfee) | Near payment form and CTA |
| PCI DSS Compliant | Near payment form |
| Money-back guarantee + return policy | Near submit button |
| Customer service contact | Checkout footer |

Security badges increase conversion 15-42%. "Your payment information is encrypted and secure" near card fields.

### Order Summary, Promo Codes, Auto-Fill

**Order summary**: Always visible — desktop sidebar, mobile collapsible with total shown. Sticky positioning.

**Promo field**: Visible fields cause 20-30% of users to leave searching for codes. Best: remove entirely (auto-apply). Good: collapse behind "Have a promo code?". Removing the field: +3-5% conversion.

**Auto-fill**: Use proper `autocomplete` attributes (`email`, `given-name`, `family-name`, `shipping street-address`, `shipping postal-code`, `tel`) — reduces checkout time 50%+. Address autocomplete via Google Places API, Loqate, or Smarty Streets. Smart defaults: country from IP, pre-check "Billing = Shipping" (~90% use same).

### Error Handling and Mobile

**Errors**: Inline validation on-blur; debounced on-keystroke for email/phone/card. Never validate only on submit. Specific messages ("Credit card should be 15-16 digits. You entered 15."). Show error summary at top on submit. Always preserve entered data.

**Mobile** (50%+ transactions, 2-3× lower conversion than desktop):

- `type="email"` / `type="tel"` for correct keyboards; `font-size: 16px` to prevent iOS zoom
- Min 48×48px touch targets; single-column layout
- Digital wallets above the fold; sticky "Place Order" button (`position: sticky; bottom: 0`)
- Minimize typing: dropdowns for states, autofill, address autocomplete

### Submission and Page Speed

Disable button on click, show "Processing Payment...", re-enable on error. Include price in button ("Place Order - $142.00"). Speed targets: <1s TTI, <2s FCP, <3s full load.

Speed impact: 1s delay = 7% conversion loss; 3s load = 40% abandonment; 5s = 90% abandonment (Amazon). Optimizations: minimize JS, lazy-load non-critical elements, WebP via CDN, inline critical CSS, SSR checkout, async payment iframes (Stripe Elements, PayPal Smart Buttons).

### Cart Abandonment Recovery

Email recovery wins back 10-15% of abandoned checkouts.

| Email | Timing | Strategy |
|-------|--------|----------|
| #1 Reminder | 1-3 hours | Low-pressure: product image, support offer, 48h cart limit |
| #2 Incentive | 24 hours | 10% discount, time-limited code |
| #3 Last chance | 48-72 hours | Cart expiration, stock warning |
| #4 Alternatives | 5-7 days | Similar product recommendations |

Segment by cart value: High ($200+) = personal outreach; Medium ($50-200) = full sequence; Low (<$50) = emails 1 and 3 only. Don't train customers to abandon for discounts — limit to first-time abandoners. Tailor by stage: browse → "Still interested?"; cart → standard; checkout-started → "You're one click away!"

### Exit-Intent, Order Bumps, Post-Purchase

**Exit-intent**: Trigger on mouse-toward-close. Offer free shipping, discount, or live chat. Once per session, easy to close. Recovery: +3-8%. Live chat ("Need help?") often outperforms discounts.

**Order bump** (pre-payment): Checkbox add-on, 10-30% of main item price, limit 1-2 options. Take rate: 10-30%.

**Post-purchase upsell** (after confirmation): One-click add, discounted price. Take rate: 5-20%. Combined: +15-40% AOV. No dark patterns — easy "No Thanks", genuine value.

**Confirmation page**: Order number, delivery timeline, tracking link, support contact. Engagement: upsell, social sharing, referral program, guest account creation (pre-filled email), quick checkout feedback.

### A/B Testing Ideas

| Test | Expected Impact |
|------|----------------|
| Guest vs. forced account | +15-45% conversion |
| Free shipping threshold ($35/$50/$75) | Measure conversion AND AOV |
| Security badges near payment | +5-15% conversion |
| Button copy ("Place Order" vs "Buy Now - $142") | 2-8% difference |
| Phone required vs. optional | +3-10% conversion |
| Promo code visible/collapsed/removed | 2-5% change |
| Exit-intent offer type | +3-8% recovery |

### Fraud Prevention and International

**Fraud**: Risk signals: mismatched billing/shipping, high-value first order, multiple orders same IP, unusual email domain. Tools: Stripe Radar, Signifyd, Kount, Riskified, 3D Secure. Low risk = auto-approve; medium = manual review; high = decline or verify.

**International**: Display local currency (auto-detect by IP). Regional methods: US (cards, PayPal, Venmo), Europe (Klarna, SEPA), China (Alipay, WeChat Pay), India (UPI, Razorpay), LatAm (Mercado Pago, Boleto). DDP preferred — removes surprise duties. Translate at minimum error messages and button copy.

### Accessibility

Keyboard navigation for all fields/buttons; screen reader labels and ARIA; WCAG AA color contrast (4.5:1); visible focus indicators; errors associated with fields (not color-only); descriptive link text. Test with NVDA, JAWS, VoiceOver, keyboard-only, axe, WAVE.

---

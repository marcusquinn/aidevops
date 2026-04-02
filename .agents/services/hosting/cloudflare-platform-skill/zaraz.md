# Cloudflare Zaraz

Server-side tag manager offloads third-party scripts to Cloudflare's edge. Requires minimal client-side loader for event tracking and SPA integration; privacy-first data control.

## Setup

Dashboard: domain > Zaraz > Start setup. Config (`zaraz.toml`):

```toml
[settings]
auto_inject = true
debug_mode = false

[[tools]]
type = "google-analytics"
id = "G-XXXXXXXXXX"

[[tools.triggers]]
match_rule = "Pageview"
```

## Web API & E-commerce

```javascript
zaraz.track('button_click');
zaraz.track('purchase', { value: 99.99, currency: 'USD', item_id: '12345' });
zaraz.set('userId', 'user_12345');
zaraz.set({ email: '[email protected]', country: 'US' });

// E-commerce
zaraz.ecommerce('Product Viewed', { product_id: 'SKU123', name: 'Blue Widget', price: 49.99, currency: 'USD' });
zaraz.ecommerce('Product Added', { product_id: 'SKU123', quantity: 2, price: 49.99 });
zaraz.ecommerce('Order Completed', {
  order_id: 'ORD-789', total: 149.98, revenue: 149.98,
  shipping: 10.00, tax: 12.50, currency: 'USD',
  products: [{ product_id: 'SKU123', quantity: 2, price: 49.99 }]
});
```

Event names follow platform conventions (GA4: `sign_up`, FB: `Purchase`, Google Ads: `conversion`).
Data layer: `window.zaraz.dataLayer = { user_id: '12345', page_type: 'product' }`. Access in triggers: `{{client.__zarazTrack.page_type}}`.

## Consent Management

```javascript
if (zaraz.consent.getAll().analytics) { zaraz.track('page_view'); }
zaraz.consent.modal = true;
zaraz.consent.setAll({ analytics: true, marketing: false, preferences: true });
zaraz.consent.addEventListener('consentChanged', () => {
  console.log('Consent updated:', zaraz.consent.getAll());
});
```

## Triggers & Patterns

Types: Pageview, DOM Ready, Click (CSS selector), Form, Scroll (%), Timer, Variable match.
Example: Trigger `Button Click` on `.buy-button` → action `Track event "purchase_intent"`.

```javascript
// SPA route tracking
router.afterEach((to) => zaraz.track('pageview', { page_path: to.path, page_title: to.meta.title }));
// User identification on login
zaraz.set('user_id', user.id);
zaraz.track('login', { method: 'password' });
```

## Workers & Custom Components

Workers can intercept fetch events to attach Zaraz logic. Custom Managed Components allow server-side event handling:

```javascript
export default class CustomAnalytics {
  async handleEvent(event) {
    const { type, payload } = event;
    await fetch('https://analytics.example.com/track', {
      method: 'POST',
      body: JSON.stringify({ event: type, properties: payload, timestamp: Date.now() })
    });
  }
}
```

## Operations & Reference

Automatic IP anonymization, consent-based cookie control, GDPR/CCPA compliant. Unlimited tools/events; 100 KB request limit; data retention per tool policy.
Enable debug: dashboard toggle or `zaraz.debug = true`. Check triggers, tool status, console, `zaraz.consent.getAll()`.

- [Zaraz Docs](https://developers.cloudflare.com/zaraz/)
- [Web API](https://developers.cloudflare.com/zaraz/web-api/)
- [Managed Components](https://developers.cloudflare.com/zaraz/advanced/load-custom-managed-component/)

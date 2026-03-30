# Cloudflare Zaraz

Server-side tag manager: offloads third-party scripts (analytics, ads, chat) to Cloudflare's edge. Zero client-side JS overhead; single HTTP request for all tools; privacy-first data control.

## Setup

Dashboard: domain > Zaraz > Start setup > add tools > configure triggers and actions. Config file (`zaraz.toml`):

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

## Web API

```javascript
zaraz.track('button_click');
zaraz.track('purchase', { value: 99.99, currency: 'USD', item_id: '12345' });
zaraz.set('userId', 'user_12345');
zaraz.set({ email: '[email protected]', country: 'US' });
```

Tool-specific event names follow each platform's conventions (e.g. GA4: `sign_up`; Facebook Pixel: `Purchase`; Google Ads: `conversion` with `send_to`).

Data layer: `window.zaraz.dataLayer = { user_id: '12345', page_type: 'product' }`. Access in triggers: `{{client.__zarazTrack.page_type}}`.

### E-commerce

```javascript
zaraz.ecommerce('Product Viewed', { product_id: 'SKU123', name: 'Blue Widget', price: 49.99, currency: 'USD' });
zaraz.ecommerce('Product Added', { product_id: 'SKU123', quantity: 2, price: 49.99 });
zaraz.ecommerce('Order Completed', {
  order_id: 'ORD-789', total: 149.98, revenue: 149.98,
  shipping: 10.00, tax: 12.50, currency: 'USD',
  products: [{ product_id: 'SKU123', quantity: 2, price: 49.99 }]
});
```

## Consent Management

```javascript
if (zaraz.consent.getAll().analytics) { zaraz.track('page_view'); }
zaraz.consent.modal = true;
zaraz.consent.setAll({ analytics: true, marketing: false, preferences: true });
zaraz.consent.addEventListener('consentChanged', () => {
  console.log('Consent updated:', zaraz.consent.getAll());
});
```

## Triggers

| Type | Description |
|------|-------------|
| Pageview | Every page load |
| DOM Ready | When DOM is ready |
| Click | CSS selector match |
| Form submission | Form submits |
| Scroll depth | User scrolls % |
| Timer | After elapsed time |
| Variable match | Custom conditions |

Example: Trigger `Button Click` on `.buy-button` → action `Track event "purchase_intent"`.

## Custom Managed Components

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

## Common Patterns

```javascript
// SPA route tracking
router.afterEach((to) => zaraz.track('pageview', { page_path: to.path, page_title: to.meta.title }));
// User identification on login
zaraz.set('user_id', user.id);
zaraz.track('login', { method: 'password' });
```

For Workers integration patterns, see `cloudflare-workers` skill.

## Privacy & Limits

IP anonymization (automatic), consent-based cookie control, GDPR/CCPA compliance. Tools and events unlimited; request size 100 KB; data retention per tool's policy.

## Debugging

Enable debug mode in dashboard or `zaraz.debug = true`. Check: trigger conditions, tool enabled status, browser console, `zaraz.consent.getAll()` for consent issues.

## Reference

- [Zaraz Docs](https://developers.cloudflare.com/zaraz/)
- [Web API](https://developers.cloudflare.com/zaraz/web-api/)
- [Managed Components](https://developers.cloudflare.com/zaraz/advanced/load-custom-managed-component/)

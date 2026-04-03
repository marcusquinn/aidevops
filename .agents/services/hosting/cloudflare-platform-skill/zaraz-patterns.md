# Cloudflare Zaraz — Patterns

## E-commerce

```javascript
zaraz.ecommerce('Product Viewed', { product_id: 'SKU123', name: 'Blue Widget', price: 49.99, currency: 'USD' });
zaraz.ecommerce('Product Added', { product_id: 'SKU123', quantity: 2, price: 49.99 });
zaraz.ecommerce('Order Completed', { order_id: 'ORD-789', total: 149.98, revenue: 149.98, shipping: 10.00, tax: 12.50, currency: 'USD', products: [{ product_id: 'SKU123', quantity: 2, price: 49.99 }] });
```

## SPA Route Tracking

```javascript
router.afterEach((to) => zaraz.track('pageview', { page_path: to.path, page_title: to.meta.title }));
```

## User Identification

```javascript
zaraz.set('user_id', user.id);
zaraz.track('login', { method: 'password' });
```

## Consent Management

```javascript
if (zaraz.consent.getAll().analytics) { zaraz.track('page_view'); }
zaraz.consent.modal = true;
zaraz.consent.setAll({ analytics: true, marketing: false, preferences: true });
zaraz.consent.addEventListener('consentChanged', () => { /* re-fire events based on zaraz.consent.getAll() */ });
```

## Custom Managed Components

```javascript
export default class CustomAnalytics {
  async handleEvent({ type, payload }) {
    await fetch('https://analytics.example.com/track', {
      method: 'POST',
      body: JSON.stringify({ event: type, properties: payload, timestamp: Date.now() })
    });
  }
}
```

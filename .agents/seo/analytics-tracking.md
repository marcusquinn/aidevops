---
description: "When the user wants to implement or audit analytics tracking on their site. Also use when the user mentions \"GA4 setup,\" \"event tracking,\" \"conversion tracking,\" \"UTM parameters,\" \"attribution,\" \"Google Tag Manager,\" \"GTM,\" \"analytics implementation,\" \"track button clicks,\" \"goal tracking,\" or \"measurement plan.\""
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  grep: true
  webfetch: true
---

# Analytics Tracking - Implementation Guide

**Scope**: Implement and audit analytics tracking (GA4, GTM, events, conversions, UTM, attribution). For *reading* analytics data, use `services/analytics/google-analytics.md`. Docs: [GA4](https://developers.google.com/analytics/devguides/collection/ga4) · [GTM](https://developers.google.com/tag-platform/tag-manager) · [Measurement Protocol](https://developers.google.com/analytics/devguides/collection/protocol/ga4)

## GA4 Setup

**gtag.js (direct)** — add to `<head>`:

```html
<script async src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXXXXXX"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXXXXXX');
</script>
```

**GTM (recommended)** — get snippet from https://tagmanager.google.com: head snippet in `<head>`, noscript body snippet after `<body>`. Add GA4 Configuration tag (Measurement ID = `G-XXXXXXXXXX`, Trigger = All Pages).

**WordPress** — Site Kit by Google (official), MonsterInsights, or manual via `wp_head` hook.

## Event Tracking

Auto-collected: `page_view`, `first_visit`, `session_start`. Enhanced measurement (toggle): `scroll`, `click` (outbound), `file_download`, `video_start`. Implement manually: `login`/`sign_up` (`method`), `generate_lead` (`currency`, `value`, `form_name`), `purchase` (`transaction_id`, `value`, `currency`, `items`), `add_to_cart`/`begin_checkout`/`view_item` (`currency`, `value`, `items`), `search` (`search_term`), custom events (up to 25 params). Full reference: https://developers.google.com/analytics/devguides/collection/ga4/reference/events

```javascript
gtag('event', 'generate_lead', {'form_name': 'contact_form', 'currency': 'USD', 'value': 50.00});
gtag('event', 'cta_click', {'cta_text': 'Start Free Trial', 'cta_location': 'hero_section'});
// GTM data layer — create Custom Event trigger matching the event name
window.dataLayer.push({'event': 'cta_click', 'cta_text': 'Start Free Trial', 'cta_location': 'hero_section'});
```

**Limits**: event name 40 chars; param name/value 40/100 chars; 25 params/event; 50 event-scoped + 25 user-scoped custom dimensions; 50 custom metrics.

## Conversion Tracking

**Admin > Events** → toggle "Mark as key event" → assign value. Key events: `generate_lead`, `purchase`, `sign_up`, `book_demo`.

```javascript
gtag('event', 'purchase', {
  transaction_id: 'T12345', value: 99.99, tax: 8.00, shipping: 5.99,
  currency: 'USD', coupon: 'SUMMER10',
  items: [{ item_id: 'SKU-001', item_name: 'Product Name', item_brand: 'Brand', item_category: 'Category', price: 99.99, quantity: 1, discount: 10.00 }]
});
```

**E-commerce funnel**: `view_item_list` → `select_item` → `view_item` → `add_to_cart` → `view_cart` → `begin_checkout` → `add_shipping_info` → `add_payment_info` → `purchase`

**Google Ads import**: Link GA4 → **Tools > Conversions > Import > Google Analytics 4** → select key events, set counting method and conversion window (default 30 days).

## UTM Parameters

Required: `utm_source` (e.g. `google`), `utm_medium` (e.g. `cpc`, `email`), `utm_campaign` (e.g. `spring_sale_2026`). Optional: `utm_term` (paid keyword), `utm_content` (ad variant). Rules: lowercase + underscores; never on internal links (resets session source); no PII. Builder: https://ga-dev-tools.google/ga4/campaign-url-builder/

## Attribution

Two models (first-click, linear, position-based, time-decay deprecated Nov 2023): **Data-driven** (default, ML-based, needs 600+ conversions/month) and **Last click** (100% credit to last touchpoint, simple reporting). Tag all campaigns with UTMs, link Google Ads (auto-tagging via gclid) and Search Console, enable Google Signals. Use **Advertising > Attribution > Conversion paths** for assist channels.

## Google Tag Manager

Triggers: **Page View** (All Pages) · **Click - All Elements** (CSS selector) · **Click - Just Links** (outbound: URL contains `http` + not your domain) · **Form Submission** (Form ID/Classes) · **Scroll Depth** (25/50/75/90%) · **Custom Event** (event name match) · **Element Visibility** (CSS selector, once per page)

```javascript
// Page-level (before GTM container)
window.dataLayer = window.dataLayer || [];
window.dataLayer.push({'pageType': 'product', 'userLoggedIn': true, 'userType': 'premium'});
// Event (on interaction)
window.dataLayer.push({'event': 'add_to_cart', 'ecommerce': {'items': [{'item_id': 'SKU-001', 'item_name': 'Wireless Headphones', 'price': 79.99, 'quantity': 1}]}});
```

**Debugging**: GTM Preview → Tag Assistant; GA4 Admin > DebugView; Network tab filter `collect?`; Google Analytics Debugger extension.

## Measurement Plan Template

```text
Objective: [e.g., Increase online sales by 20%]
KPIs: [e.g., E-commerce conversion rate, Average order value]
Key events: purchase (value, items, tx_id), generate_lead (form_name, value), cta_click (cta_text, location)
Dimensions: page_type, user_type, traffic_source (UTM)
Segments: Purchasers vs. non-purchasers, Mobile vs. desktop, Organic vs. paid
```

## Audit Checklist

GA4 tag fires on all pages · Measurement ID correct (not UA-) · Enhanced measurement enabled · Data retention 14 months (default 2 — change in Admin) · Internal traffic filtered · Key events defined and firing · E-commerce tracking complete · Cross-domain tracking configured · UTMs used consistently · No PII in event parameters · Cookie consent implemented (GDPR/CCPA) · Google Ads and Search Console linked · Custom dimensions registered · Google Signals enabled · Audiences configured

**Common issues**: Duplicate tags → inflated pageviews (remove duplicate gtag.js/GTM containers) · Missing enhanced measurement → no scroll/click data (enable in Admin > Data Streams) · UTM on internal links → self-referrals (remove from internal nav) · No consent management → GDPR violations (implement consent mode v2) · Wrong measurement ID → no data (verify G-XXXXXXXXXX) · Data retention at 2 months → limited history (set to 14 months) · PII in events → policy violation (audit and strip)

## Consent Mode v2

Required for EU/EEA compliance and Google Ads audience features. GA4 uses behavioral modeling to fill gaps when consent is denied.

```javascript
// Default (before consent) — set before GTM/gtag loads
gtag('consent', 'default', {'ad_storage': 'denied', 'ad_user_data': 'denied', 'ad_personalization': 'denied', 'analytics_storage': 'denied'});
// After user grants consent
gtag('consent', 'update', {'ad_storage': 'granted', 'ad_user_data': 'granted', 'ad_personalization': 'granted', 'analytics_storage': 'granted'});
```

## Server-Side Tracking

**Server-Side GTM**: Create server container → deploy to Cloud Run/App Engine → route client-side tags through it. Benefits: first-party cookies, reduced client JS, ad-blocker resistance.

**Measurement Protocol** (direct server events):

```bash
curl -X POST "https://www.google-analytics.com/mp/collect?measurement_id=G-XXXXXXXXXX&api_secret=YOUR_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"client_id": "client_id_value", "events": [{"name": "purchase", "params": {"transaction_id": "T12345", "value": 99.99, "currency": "USD", "items": [{"item_id": "SKU-001", "item_name": "Product", "price": 99.99, "quantity": 1}]}}]}'
```

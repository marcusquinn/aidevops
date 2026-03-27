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

<!-- AI-CONTEXT-START -->

**Scope**: Implement and audit analytics tracking (GA4, GTM, events, conversions, UTM, attribution). For *reading* analytics data, use `services/analytics/google-analytics.md` (GA4 MCP).

- **GA4 docs**: https://developers.google.com/analytics/devguides/collection/ga4
- **GTM docs**: https://developers.google.com/tag-platform/tag-manager
- **Measurement Protocol**: https://developers.google.com/analytics/devguides/collection/protocol/ga4
- **Related**: `seo/seo-audit-skill.md` (technical SEO audit)

<!-- AI-CONTEXT-END -->

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

**Google Tag Manager (recommended)** — get snippet from https://tagmanager.google.com: head snippet in `<head>`, noscript body snippet immediately after `<body>`. Then add GA4 Configuration tag (Measurement ID = `G-XXXXXXXXXX`, Trigger = All Pages).

**WordPress** — Site Kit by Google (official), MonsterInsights, or manual via `wp_head` hook.

## Event Tracking

### GA4 Event Model

| Event Category | Examples | Parameters | Auto-collected? |
|---------------|----------|------------|-----------------|
| Automatically collected | `page_view`, `first_visit`, `session_start` | — | Yes |
| Enhanced measurement | `scroll`, `click` (outbound), `file_download`, `video_start` | — | Yes (toggle) |
| `login`, `sign_up` | New account / session | `method` | No (implement) |
| `generate_lead` | Lead form submission | `currency`, `value`, `form_name` | No (implement) |
| `purchase` | Completed purchase | `transaction_id`, `value`, `currency`, `items` | No (implement) |
| `add_to_cart`, `begin_checkout`, `view_item` | E-commerce funnel | `currency`, `value`, `items` | No (implement) |
| `search` | Site search | `search_term` | No (implement) |
| Custom events | Any business-specific event | Up to 25 custom params | No (implement) |

Full event reference: https://developers.google.com/analytics/devguides/collection/ga4/reference/events

### Implementing Custom Events

```javascript
// gtag.js
gtag('event', 'generate_lead', {'form_name': 'contact_form', 'currency': 'USD', 'value': 50.00});
gtag('event', 'cta_click', {'cta_text': 'Start Free Trial', 'cta_location': 'hero_section'});
// GTM data layer — then create Custom Event trigger matching the event name
window.dataLayer.push({'event': 'cta_click', 'cta_text': 'Start Free Trial', 'cta_location': 'hero_section'});
```

### Event Parameter Limits

| Limit | Value |
|-------|-------|
| Event name length | 40 characters |
| Parameter name/value length | 40 / 100 characters |
| Parameters per event | 25 |
| Custom dimensions per property | 50 event-scoped, 25 user-scoped |
| Custom metrics per property | 50 |

## Conversion Tracking

**Admin > Events** → toggle "Mark as key event" → assign value (optional). Key events: `generate_lead` (lead value), `purchase` (transaction value), `sign_up` (LTV estimate), `book_demo` (pipeline value).

### E-commerce Tracking

```javascript
gtag('event', 'purchase', {
  transaction_id: 'T12345', value: 99.99, tax: 8.00, shipping: 5.99,
  currency: 'USD', coupon: 'SUMMER10',
  items: [{ item_id: 'SKU-001', item_name: 'Product Name', item_brand: 'Brand', item_category: 'Category', price: 99.99, quantity: 1, discount: 10.00 }]
});
```

**Funnel**: `view_item_list` → `select_item` → `view_item` → `add_to_cart` → `view_cart` → `begin_checkout` → `add_shipping_info` → `add_payment_info` → `purchase`

**Google Ads import**: Link GA4 to Google Ads → **Tools > Conversions > Import > Google Analytics 4** → select key events, set counting method and conversion window (default 30 days).

## UTM Parameters

| Parameter | Required | Purpose | Example |
|-----------|----------|---------|---------|
| `utm_source` | Yes | Traffic source | `google`, `newsletter` |
| `utm_medium` | Yes | Marketing medium | `cpc`, `email`, `social` |
| `utm_campaign` | Yes | Campaign name | `spring_sale_2026` |
| `utm_term` | No | Paid keyword | `running+shoes` |
| `utm_content` | No | Ad/link variant | `header_cta` |

**Naming conventions**: lowercase, underscores, no spaces. Standard mediums: `cpc`, `email`, `social`, `referral`, `display`, `affiliate`.

- **Never use UTMs for internal links** — they reset the session source
- **Use lowercase consistently** — GA4 is case-sensitive (`Email` != `email`)
- **Avoid PII** in UTM values (no email addresses or user IDs)
- URL builder: https://ga-dev-tools.google/ga4/campaign-url-builder/

## Attribution

GA4 supports two models (Google deprecated first-click, linear, position-based, and time-decay in November 2023):

| Model | How it works | Best for |
|-------|-------------|----------|
| **Data-driven** (default) | ML-based, distributes credit by actual contribution | Most accounts (needs 600+ conversions/month) |
| **Last click** | 100% credit to last touchpoint | Simple reporting, direct response |

**Cross-channel setup**: Tag all campaigns with UTMs, link Google Ads (auto-tagging via gclid), link Search Console, enable Google Signals, set lookback window (30–90 days). Use **Advertising > Attribution > Conversion paths** to identify assist channels.

## Google Tag Manager

### Common GTM Triggers

| Trigger Type | Use Case | Configuration |
|-------------|----------|---------------|
| Page View | Track all pages | All Pages (built-in) |
| Click - All Elements | Button/link clicks | Click Element matches CSS selector |
| Click - Just Links | Outbound links | Click URL contains `http` + not your domain |
| Form Submission | Lead forms | Form ID or Form Classes |
| Scroll Depth | Content engagement | Vertical scroll 25%, 50%, 75%, 90% |
| Custom Event | Data layer events | Event name matches |
| Element Visibility | Section views | CSS selector, once per page |

### Data Layer Best Practices

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

## Auditing Existing Tracking

### Quick Audit Checklist

- [ ] GA4 tag fires on all pages (check with Tag Assistant)
- [ ] Measurement ID is correct (not a UA- property)
- [ ] Enhanced measurement enabled
- [ ] Data retention set to 14 months (default is 2 months — change in Admin)
- [ ] Internal traffic filtered (exclude office IPs)
- [ ] Key events (conversions) defined and firing
- [ ] E-commerce tracking complete (if applicable)
- [ ] Cross-domain tracking configured (if multiple domains)
- [ ] UTM parameters used consistently on campaigns
- [ ] No PII sent to GA4 (email addresses, names in event parameters)
- [ ] Cookie consent implemented (GDPR/CCPA compliance)
- [ ] Google Ads and Search Console linked
- [ ] Custom dimensions registered for custom parameters
- [ ] Google Signals enabled (for cross-device reporting)
- [ ] Audiences configured for remarketing

### Common Issues

| Issue | Symptom | Fix |
|-------|---------|-----|
| Duplicate tags | Inflated pageviews | Remove duplicate gtag.js or GTM containers |
| Missing enhanced measurement | No scroll/click data | Enable in GA4 Admin > Data Streams |
| UTM on internal links | Self-referrals, broken sessions | Remove UTMs from internal navigation |
| No consent management | GDPR violations, data loss | Implement consent mode v2 |
| Wrong measurement ID | No data in property | Verify G-XXXXXXXXXX matches property |
| Data retention at 2 months | Limited historical analysis | Set to 14 months in Admin |
| PII in events | Policy violation | Audit event parameters, strip PII |

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

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

### Installation Methods

**Method 1: gtag.js (direct)** — add to `<head>` before other scripts:

```html
<script async src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXXXXXX"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXXXXXX');
</script>
```

**Method 2: Google Tag Manager (recommended)**

```html
<!-- GTM head snippet -->
<script>(function(w,d,s,l,i){w[l]=w[l]||[];w[l].push({'gtm.start':
new Date().getTime(),event:'gtm.js'});var f=d.getElementsByTagName(s)[0],
j=d.createElement(s),dl=l!='dataLayer'?'&l='+l:'';j.async=true;j.src=
'https://www.googletagmanager.com/gtm.js?id='+i+dl;f.parentNode.insertBefore(j,f);
})(window,document,'script','dataLayer','GTM-XXXXXXX');</script>

<!-- GTM body snippet (immediately after <body>) -->
<noscript><iframe src="https://www.googletagmanager.com/ns.html?id=GTM-XXXXXXX"
height="0" width="0" style="display:none;visibility:hidden"></iframe></noscript>
```

**Method 3: WordPress** — Site Kit by Google (official), MonsterInsights, or manual via `wp_head` hook.

### GA4 Property Configuration Checklist

- [ ] Create web data stream with correct URL
- [ ] Enable enhanced measurement (scrolls, outbound clicks, site search, video, file downloads)
- [ ] Set data retention to 14 months (default is 2 months)
- [ ] Link Google Ads account (if running ads)
- [ ] Link Search Console property
- [ ] Configure cross-domain tracking (if multiple domains)
- [ ] Set up internal traffic filters (exclude office IPs)
- [ ] Enable Google Signals (for cross-device reporting)
- [ ] Define key events (conversions)
- [ ] Set up audiences for remarketing

## Event Tracking

### GA4 Event Model

| Event Category | Examples | Auto-collected? |
|---------------|----------|-----------------|
| Automatically collected | `page_view`, `first_visit`, `session_start` | Yes |
| Enhanced measurement | `scroll`, `click` (outbound), `file_download`, `video_start` | Yes (toggle) |
| Recommended events | `login`, `sign_up`, `purchase`, `add_to_cart`, `generate_lead` | No (implement) |
| Custom events | Any business-specific event | No (implement) |

### Implementing Custom Events

**Via gtag.js**:

```javascript
gtag('event', 'cta_click', {
  'cta_text': 'Start Free Trial',
  'cta_location': 'hero_section',
  'page_type': 'landing_page'
});

gtag('event', 'generate_lead', {
  'form_name': 'contact_form',
  'currency': 'USD',
  'value': 50.00
});
```

**Via data layer (GTM)**:

```javascript
window.dataLayer.push({'event': 'cta_click', 'cta_text': 'Start Free Trial', 'cta_location': 'hero_section'});
```

Then create a matching trigger in GTM: Custom Event > Event name = `cta_click`.

### Recommended Events Reference

| Event | Parameters | Use Case |
|-------|-----------|----------|
| `login` | `method` | User logs in |
| `sign_up` | `method` | New account creation |
| `generate_lead` | `currency`, `value` | Lead form submission |
| `purchase` | `transaction_id`, `value`, `currency`, `items` | Completed purchase |
| `add_to_cart` | `currency`, `value`, `items` | Product added to cart |
| `begin_checkout` | `currency`, `value`, `items` | Checkout started |
| `view_item` | `currency`, `value`, `items` | Product page view |
| `search` | `search_term` | Site search |

Full list: https://developers.google.com/analytics/devguides/collection/ga4/reference/events

### Event Parameter Limits

| Limit | Value |
|-------|-------|
| Event name length | 40 characters |
| Parameter name/value length | 40 / 100 characters |
| Parameters per event | 25 |
| Custom dimensions per property | 50 event-scoped, 25 user-scoped |
| Custom metrics per property | 50 |

## Conversion Tracking

### Setting Up Key Events

1. **Admin > Events** — find or create the event
2. **Toggle "Mark as key event"** — enables conversion reporting
3. **Assign value** (optional) — static or dynamic

| Key Event | Trigger | Value |
|-----------|---------|-------|
| `generate_lead` | Contact form submission | Estimated lead value |
| `purchase` | Order confirmation page | Transaction value |
| `sign_up` | Registration complete | Lifetime value estimate |
| `book_demo` | Demo booking confirmed | Pipeline value |

### E-commerce Tracking

```javascript
gtag('event', 'purchase', {
  transaction_id: 'T12345', value: 99.99, tax: 8.00, shipping: 5.99,
  currency: 'USD', coupon: 'SUMMER10',
  items: [{
    item_id: 'SKU-001', item_name: 'Product Name', item_brand: 'Brand',
    item_category: 'Category', price: 99.99, quantity: 1, discount: 10.00
  }]
});
```

**E-commerce funnel**: `view_item_list` → `select_item` → `view_item` → `add_to_cart` → `view_cart` → `begin_checkout` → `add_shipping_info` → `add_payment_info` → `purchase`

### Google Ads Conversion Import

1. Link GA4 property to Google Ads account
2. Google Ads: **Tools > Conversions > Import > Google Analytics 4**
3. Select key events, set counting method and conversion window (default 30 days)

## UTM Parameters

### Standard Parameters

| Parameter | Required | Purpose | Example |
|-----------|----------|---------|---------|
| `utm_source` | Yes | Traffic source | `google`, `newsletter` |
| `utm_medium` | Yes | Marketing medium | `cpc`, `email`, `social` |
| `utm_campaign` | Yes | Campaign name | `spring_sale_2026` |
| `utm_term` | No | Paid keyword | `running+shoes` |
| `utm_content` | No | Ad/link variant | `header_cta` |

### Naming Conventions & Best Practices

```text
Source:    lowercase, no spaces (google, facebook, linkedin, newsletter)
Medium:    standard values (cpc, email, social, referral, display, affiliate)
Campaign:  lowercase, underscores (spring_sale_2026, product_launch_q1)
Content:   descriptive, underscores (hero_cta, footer_link, variant_a)
Term:      plus-separated keywords (running+shoes)
```

- **Never use UTMs for internal links** — they reset the session source
- **Use lowercase consistently** — GA4 is case-sensitive (`Email` != `email`)
- **Avoid PII** in UTM values (no email addresses or user IDs)
- URL builder: https://ga-dev-tools.google/ga4/campaign-url-builder/

```javascript
function buildUTMUrl(baseUrl, params) {
  const url = new URL(baseUrl);
  if (params.source) url.searchParams.set('utm_source', params.source);
  if (params.medium) url.searchParams.set('utm_medium', params.medium);
  if (params.campaign) url.searchParams.set('utm_campaign', params.campaign);
  if (params.term) url.searchParams.set('utm_term', params.term);
  if (params.content) url.searchParams.set('utm_content', params.content);
  return url.toString();
}
```

## Attribution

### GA4 Attribution Models

| Model | How it works | Best for |
|-------|-------------|----------|
| **Data-driven** (default) | ML-based, distributes credit by actual contribution | Most accounts (needs 600+ conversions/month) |
| **Last click** | 100% credit to last touchpoint | Simple reporting, direct response |

Note: Google deprecated first-click, linear, position-based, and time-decay models in GA4 (November 2023). Only data-driven and last-click remain.

### Cross-Channel Attribution Setup

1. Tag all campaigns with UTM parameters
2. Link Google Ads for auto-tagging (gclid)
3. Link Search Console for organic search data
4. Enable Google Signals for cross-device tracking
5. Set lookback window (30–90 days depending on sales cycle)

Use **Advertising > Attribution > Conversion paths** to identify assist channels and optimize budget allocation.

## Google Tag Manager

### Container Setup

1. Create account at https://tagmanager.google.com, create Web container
2. Install container snippet (see GA4 Setup above)
3. Add GA4 Configuration tag: type = GA4 Configuration, Measurement ID = `G-XXXXXXXXXX`, Trigger = All Pages

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
// Page-level data (before GTM container)
window.dataLayer = window.dataLayer || [];
window.dataLayer.push({'pageType': 'product', 'userLoggedIn': true, 'userType': 'premium'});

// Event data (on interaction)
window.dataLayer.push({
  'event': 'add_to_cart',
  'ecommerce': {'items': [{'item_id': 'SKU-001', 'item_name': 'Wireless Headphones', 'price': 79.99, 'quantity': 1}]}
});
```

**Debugging**: GTM Preview mode → Tag Assistant; GA4 Admin > DebugView; Network tab filter `collect?`; Google Analytics Debugger Chrome extension.

## Measurement Plan Template

```text
Business Objective: [e.g., Increase online sales by 20%]

KPIs:
  1. [e.g., E-commerce conversion rate]
  2. [e.g., Average order value]

Events to Track:
  | Event Name     | Trigger            | Parameters          | Key Event? |
  |----------------|--------------------|---------------------|------------|
  | purchase       | Order confirmation | value, items, tx_id | Yes        |
  | generate_lead  | Form submit        | form_name, value    | Yes        |
  | cta_click      | CTA button click   | cta_text, location  | No         |

Dimensions: page_type, user_type, traffic_source (from UTM)
Segments: Purchasers vs. non-purchasers, Mobile vs. desktop, Organic vs. paid
```

## Auditing Existing Tracking

### Quick Audit Checklist

- [ ] GA4 tag fires on all pages (check with Tag Assistant)
- [ ] Measurement ID is correct (not a UA- property)
- [ ] Enhanced measurement enabled
- [ ] Data retention set to 14 months
- [ ] Internal traffic filtered
- [ ] Key events (conversions) defined and firing
- [ ] E-commerce tracking complete (if applicable)
- [ ] Cross-domain tracking configured (if multiple domains)
- [ ] UTM parameters used consistently on campaigns
- [ ] No PII sent to GA4 (email addresses, names in event parameters)
- [ ] Cookie consent implemented (GDPR/CCPA compliance)
- [ ] Google Ads and Search Console linked
- [ ] Custom dimensions registered for custom parameters

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

Required for EU/EEA compliance and Google Ads audience features:

```javascript
// Default state (before consent)
gtag('consent', 'default', {
  'ad_storage': 'denied', 'ad_user_data': 'denied',
  'ad_personalization': 'denied', 'analytics_storage': 'denied'
});

// After user grants consent
gtag('consent', 'update', {
  'ad_storage': 'granted', 'ad_user_data': 'granted',
  'ad_personalization': 'granted', 'analytics_storage': 'granted'
});
```

GA4 uses behavioral modeling to fill gaps when consent is denied.

## Server-Side Tracking

### GA4 Measurement Protocol

```bash
curl -X POST "https://www.google-analytics.com/mp/collect?measurement_id=G-XXXXXXXXXX&api_secret=YOUR_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "client_id_value",
    "events": [{"name": "purchase", "params": {
      "transaction_id": "T12345", "value": 99.99, "currency": "USD",
      "items": [{"item_id": "SKU-001", "item_name": "Product", "price": 99.99, "quantity": 1}]
    }}]
  }'
```

### Server-Side GTM

1. Create server container in GTM
2. Deploy to Cloud Run, App Engine, or custom server
3. Route client-side tags through server container

Benefits: first-party cookies, reduced client JS, ad-blocker resistance.

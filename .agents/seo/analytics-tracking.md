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

## Quick Reference

- **Purpose**: Implement and audit analytics tracking (GA4, GTM, events, conversions, UTM, attribution)
- **Related**: `services/analytics/google-analytics.md` (GA4 MCP API for reporting), `seo/seo-audit-skill.md` (technical SEO audit)
- **GA4 docs**: https://developers.google.com/analytics/devguides/collection/ga4
- **GTM docs**: https://developers.google.com/tag-platform/tag-manager
- **Measurement Protocol**: https://developers.google.com/analytics/devguides/collection/protocol/ga4

**Scope distinction**: This subagent covers *implementation* (adding tracking to sites). For *reading analytics data*, use `services/analytics/google-analytics.md` (GA4 MCP).

**Key areas**:

| Area | What it covers |
|------|---------------|
| GA4 Setup | Property creation, data streams, gtag.js / GTM installation |
| Event Tracking | Custom events, recommended events, event parameters |
| Conversion Tracking | Key events, e-commerce tracking, lead generation |
| UTM Parameters | Campaign tagging, URL builder, naming conventions |
| Attribution | Models (data-driven, last-click, first-click), conversion paths |
| Google Tag Manager | Container setup, triggers, variables, data layer |
| Debugging | GA4 DebugView, Tag Assistant, real-time reports |

<!-- AI-CONTEXT-END -->

## GA4 Setup

### Installation Methods

**Method 1: gtag.js (direct)**

Add to `<head>` on every page, before other scripts:

```html
<!-- Google tag (gtag.js) -->
<script async src="https://www.googletagmanager.com/gtag/js?id=G-XXXXXXXXXX"></script>
<script>
  window.dataLayer = window.dataLayer || [];
  function gtag(){dataLayer.push(arguments);}
  gtag('js', new Date());
  gtag('config', 'G-XXXXXXXXXX');
</script>
```

**Method 2: Google Tag Manager (recommended for most sites)**

Add GTM container to `<head>` and `<body>`:

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

**Method 3: WordPress**

- **Site Kit by Google** (official plugin): Handles GA4 + Search Console + AdSense
- **MonsterInsights**: GA4 with enhanced e-commerce
- **Manual**: Add gtag.js via theme `functions.php` or `wp_head` hook

### GA4 Property Configuration Checklist

After creating a GA4 property in the admin console:

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

GA4 uses an event-based model (not sessions/pageviews like Universal Analytics):

| Event Category | Examples | Auto-collected? |
|---------------|----------|-----------------|
| **Automatically collected** | `page_view`, `first_visit`, `session_start` | Yes |
| **Enhanced measurement** | `scroll`, `click` (outbound), `file_download`, `video_start`, `view_search_results` | Yes (toggle) |
| **Recommended events** | `login`, `sign_up`, `purchase`, `add_to_cart`, `generate_lead` | No (implement) |
| **Custom events** | Any business-specific event | No (implement) |

### Implementing Custom Events

**Via gtag.js**:

```javascript
// Basic event
gtag('event', 'event_name', {
  'parameter_1': 'value_1',
  'parameter_2': 'value_2'
});

// Example: Track CTA button click
gtag('event', 'cta_click', {
  'cta_text': 'Start Free Trial',
  'cta_location': 'hero_section',
  'page_type': 'landing_page'
});

// Example: Track form submission
gtag('event', 'generate_lead', {
  'form_name': 'contact_form',
  'form_location': 'footer',
  'currency': 'USD',
  'value': 50.00
});
```

**Via data layer (for GTM)**:

```javascript
// Push event to data layer
window.dataLayer.push({
  'event': 'cta_click',
  'cta_text': 'Start Free Trial',
  'cta_location': 'hero_section'
});
```

Then create a matching trigger in GTM: Custom Event > Event name = `cta_click`.

### Recommended Events Reference

Use Google's recommended event names for automatic reporting features:

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
| `share` | `method`, `content_type`, `item_id` | Content shared |
| `select_content` | `content_type`, `content_id` | Content selection |

Full list: https://developers.google.com/analytics/devguides/collection/ga4/reference/events

### Event Parameter Limits

| Limit | Value |
|-------|-------|
| Event name length | 40 characters |
| Parameter name length | 40 characters |
| Parameter value length | 100 characters |
| Parameters per event | 25 |
| Custom dimensions per property | 50 event-scoped, 25 user-scoped |
| Custom metrics per property | 50 |

## Conversion Tracking

### Setting Up Key Events (Conversions)

In GA4, conversions are called "key events":

1. **Admin > Events** - Find or create the event
2. **Toggle "Mark as key event"** - Enables conversion reporting
3. **Assign value** (optional) - Static or dynamic value

**Common key events**:

| Key Event | Trigger | Value |
|-----------|---------|-------|
| `generate_lead` | Contact form submission | Estimated lead value |
| `purchase` | Order confirmation page | Transaction value |
| `sign_up` | Registration complete | Lifetime value estimate |
| `phone_call` | Click-to-call link | Estimated call value |
| `download` | Resource download | Content value |
| `book_demo` | Demo booking confirmed | Pipeline value |

### E-commerce Tracking

GA4 e-commerce requires structured `items` arrays:

```javascript
gtag('event', 'purchase', {
  transaction_id: 'T12345',
  value: 99.99,
  tax: 8.00,
  shipping: 5.99,
  currency: 'USD',
  coupon: 'SUMMER10',
  items: [{
    item_id: 'SKU-001',
    item_name: 'Product Name',
    item_brand: 'Brand',
    item_category: 'Category',
    item_variant: 'Blue / Large',
    price: 99.99,
    quantity: 1,
    coupon: 'SUMMER10',
    discount: 10.00
  }]
});
```

**E-commerce funnel events** (implement in order):

1. `view_item_list` - Category/search results page
2. `select_item` - Click on product
3. `view_item` - Product detail page
4. `add_to_cart` - Add to cart
5. `view_cart` - View cart
6. `begin_checkout` - Start checkout
7. `add_shipping_info` - Shipping step
8. `add_payment_info` - Payment step
9. `purchase` - Order complete

### Google Ads Conversion Import

Link GA4 key events to Google Ads:

1. Link GA4 property to Google Ads account
2. In Google Ads: **Tools > Conversions > Import > Google Analytics 4**
3. Select key events to import
4. Set counting method (one per click vs. every)
5. Set conversion window (default 30 days)

## UTM Parameters

### Standard UTM Parameters

| Parameter | Required | Purpose | Example |
|-----------|----------|---------|---------|
| `utm_source` | Yes | Traffic source | `google`, `newsletter`, `facebook` |
| `utm_medium` | Yes | Marketing medium | `cpc`, `email`, `social`, `organic` |
| `utm_campaign` | Yes | Campaign name | `spring_sale_2026`, `product_launch` |
| `utm_term` | No | Paid keyword | `running+shoes` |
| `utm_content` | No | Ad/link variant | `header_cta`, `sidebar_banner` |

### UTM Naming Conventions

Consistency is critical. Establish and enforce these rules:

```text
Source:    lowercase, no spaces (google, facebook, linkedin, newsletter)
Medium:    use standard values (cpc, email, social, referral, display, affiliate)
Campaign:  lowercase, underscores (spring_sale_2026, product_launch_q1)
Content:   descriptive, underscores (hero_cta, footer_link, variant_a)
Term:      plus-separated keywords (running+shoes, best+crm)
```

**URL builder example**:

```text
https://example.com/landing-page
  ?utm_source=google
  &utm_medium=cpc
  &utm_campaign=spring_sale_2026
  &utm_content=responsive_ad_v2
  &utm_term=running+shoes
```

### UTM Best Practices

- **Never use UTMs for internal links** - They reset the session source
- **Use a URL shortener** for social/email (long UTM URLs look spammy)
- **Document conventions** in a shared spreadsheet
- **Use lowercase consistently** - GA4 is case-sensitive (`Email` != `email`)
- **Avoid PII** in UTM values (no email addresses or user IDs)
- **Test before launching** - Verify parameters appear in GA4 real-time reports

### Campaign URL Builder

Google provides an official tool: https://ga-dev-tools.google/ga4/campaign-url-builder/

For programmatic generation:

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

GA4 supports these attribution models (set in Admin > Attribution settings):

| Model | How it works | Best for |
|-------|-------------|----------|
| **Data-driven** (default) | ML-based, distributes credit by actual contribution | Most accounts (needs sufficient data) |
| **Last click** | 100% credit to last touchpoint | Simple reporting, direct response |
| **First click** | 100% credit to first touchpoint | Understanding acquisition channels |
| **Linear** | Equal credit to all touchpoints | Valuing full customer journey |
| **Position-based** | 40% first, 40% last, 20% middle | Balanced acquisition + conversion |
| **Time decay** | More credit to recent touchpoints | Short sales cycles |

**Note**: Google deprecated first-click, linear, position-based, and time-decay models in GA4 as of November 2023. Only **data-driven** and **last-click** remain as options. The others are listed for reference when migrating from Universal Analytics.

### Conversion Paths Report

In GA4: **Advertising > Attribution > Conversion paths**

Shows the sequence of channels users interact with before converting. Use this to:

- Identify assist channels (channels that start journeys but don't close)
- Justify upper-funnel spend (display, social awareness)
- Optimize budget allocation across channels

### Cross-Channel Attribution Setup

For accurate attribution across channels:

1. **Tag all campaigns** with UTM parameters (see above)
2. **Link Google Ads** for auto-tagging (gclid)
3. **Link Search Console** for organic search data
4. **Enable Google Signals** for cross-device tracking
5. **Set lookback window** appropriately (30-90 days depending on sales cycle)
6. **Use data-driven model** when you have 600+ conversions/month

## Google Tag Manager

### Container Setup

1. Create account at https://tagmanager.google.com
2. Create container (Web type)
3. Install container snippet (see GA4 Setup above)
4. Add GA4 Configuration tag:
   - Tag type: Google Analytics: GA4 Configuration
   - Measurement ID: `G-XXXXXXXXXX`
   - Trigger: All Pages

### Common GTM Triggers

| Trigger Type | Use Case | Configuration |
|-------------|----------|---------------|
| Page View | Track all pages | All Pages (built-in) |
| Click - All Elements | Button/link clicks | Click Element matches CSS selector |
| Click - Just Links | Outbound links | Click URL contains `http` + not your domain |
| Form Submission | Lead forms | Form ID or Form Classes |
| Scroll Depth | Content engagement | Vertical scroll 25%, 50%, 75%, 90% |
| Timer | Time on page | Interval 30000ms, limit 1 |
| Custom Event | Data layer events | Event name matches |
| Element Visibility | Section views | CSS selector, once per page |

### Data Layer Best Practices

Push structured data for GTM to consume:

```javascript
// Page-level data (before GTM container)
window.dataLayer = window.dataLayer || [];
window.dataLayer.push({
  'pageType': 'product',
  'pageCategory': 'electronics',
  'userLoggedIn': true,
  'userType': 'premium'
});

// Event data (on interaction)
window.dataLayer.push({
  'event': 'add_to_cart',
  'ecommerce': {
    'items': [{
      'item_id': 'SKU-001',
      'item_name': 'Wireless Headphones',
      'price': 79.99,
      'quantity': 1
    }]
  }
});
```

### GTM Debugging

1. **Preview mode**: Click "Preview" in GTM workspace, opens Tag Assistant
2. **GA4 DebugView**: Admin > DebugView (shows events in real-time from debug sessions)
3. **Browser DevTools**: Network tab, filter by `collect?` to see GA4 hits
4. **Chrome extension**: Google Analytics Debugger (verbose console logging)

## Measurement Plan Template

Before implementing tracking, document what to measure:

```text
Business Objective: [e.g., Increase online sales by 20%]

KPIs:
  1. [e.g., E-commerce conversion rate]
  2. [e.g., Average order value]
  3. [e.g., Cart abandonment rate]

Events to Track:
  | Event Name       | Trigger              | Parameters           | Key Event? |
  |-----------------|----------------------|----------------------|------------|
  | purchase        | Order confirmation   | value, items, tx_id  | Yes        |
  | add_to_cart     | Add button click     | item_id, value       | No         |
  | generate_lead   | Form submit          | form_name, value     | Yes        |
  | cta_click       | CTA button click     | cta_text, location   | No         |

Dimensions:
  - page_type (product, category, blog, landing)
  - user_type (new, returning, premium)
  - traffic_source (from UTM)

Segments:
  - Purchasers vs. non-purchasers
  - Mobile vs. desktop
  - Organic vs. paid traffic
```

## Auditing Existing Tracking

### Quick Audit Checklist

- [ ] GA4 tag fires on all pages (check with Tag Assistant)
- [ ] Measurement ID is correct (not a UA- property)
- [ ] Enhanced measurement enabled (scrolls, outbound clicks, search, video, downloads)
- [ ] Data retention set to 14 months
- [ ] Internal traffic filtered
- [ ] Key events (conversions) defined and firing
- [ ] E-commerce tracking complete (if applicable)
- [ ] Cross-domain tracking configured (if multiple domains)
- [ ] UTM parameters used consistently on campaigns
- [ ] No PII sent to GA4 (email addresses, names in event parameters)
- [ ] Cookie consent implemented (GDPR/CCPA compliance)
- [ ] Google Ads linked (if running ads)
- [ ] Search Console linked
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
| PII in events | Policy violation, data deletion | Audit event parameters, strip PII |

## Consent Mode v2

Required for EU/EEA compliance and Google Ads audience features:

```javascript
// Default state (before consent)
gtag('consent', 'default', {
  'ad_storage': 'denied',
  'ad_user_data': 'denied',
  'ad_personalization': 'denied',
  'analytics_storage': 'denied'
});

// After user grants consent
gtag('consent', 'update', {
  'ad_storage': 'granted',
  'ad_user_data': 'granted',
  'ad_personalization': 'granted',
  'analytics_storage': 'granted'
});
```

GA4 uses **behavioral modeling** to fill gaps when consent is denied, maintaining reporting accuracy while respecting user privacy.

## Server-Side Tracking

For improved data quality and privacy control:

### GA4 Measurement Protocol

Send events server-side (bypasses ad blockers, improves accuracy):

```bash
curl -X POST "https://www.google-analytics.com/mp/collect?measurement_id=G-XXXXXXXXXX&api_secret=YOUR_SECRET" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "client_id_value",
    "events": [{
      "name": "purchase",
      "params": {
        "transaction_id": "T12345",
        "value": 99.99,
        "currency": "USD",
        "items": [{
          "item_id": "SKU-001",
          "item_name": "Product",
          "price": 99.99,
          "quantity": 1
        }]
      }
    }]
  }'
```

### Server-Side GTM

For advanced setups, deploy a server-side GTM container:

1. Create server container in GTM
2. Deploy to Cloud Run, App Engine, or custom server
3. Route client-side tags through server container
4. Benefits: first-party cookies, reduced client JS, ad-blocker resistance

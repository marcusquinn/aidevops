<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloudflare Zaraz

Server-side tag manager: offloads third-party scripts (analytics, ads, chat) to Cloudflare's edge. Zero client-side JS; single HTTP request for all tools; privacy-first data control.

## Setup

Dashboard: domain > Zaraz > Start setup > add tools > configure triggers/actions. Config (`zaraz.toml`):

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

Event names follow platform conventions (GA4: `sign_up`; Facebook Pixel: `Purchase`; Google Ads: `conversion` with `send_to`).

Data layer: `window.zaraz.dataLayer = { user_id: '12345', page_type: 'product' }`. Access in triggers: `{{client.__zarazTrack.page_type}}`.

## Triggers

Types: Pageview, DOM Ready, Click (CSS selector), Form submission, Scroll depth (%), Timer, Variable match (custom conditions).

Example: Trigger `Button Click` on `.buy-button` → action `Track event "purchase_intent"`.

## Privacy & Limits

Automatic IP anonymization, consent-based cookie control, GDPR/CCPA compliant. Tools/events unlimited; request size 100 KB; data retention per tool's policy.

## In This Reference

- [zaraz-patterns.md](./zaraz-patterns.md) - E-commerce, SPA tracking, consent management, custom components
- [zaraz-gotchas.md](./zaraz-gotchas.md) - Debugging, trigger troubleshooting, consent issues

## See Also

- [Zaraz Docs](https://developers.cloudflare.com/zaraz/)
- [Web API](https://developers.cloudflare.com/zaraz/web-api/)
- [Managed Components](https://developers.cloudflare.com/zaraz/advanced/load-custom-managed-component/)
- `cloudflare-workers` skill — Workers integration

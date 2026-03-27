---
description: Email testing suite - design rendering, delivery testing, and inbox placement
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
---

# Email Testing Suite

<!-- AI-CONTEXT-START -->

- **Script**: `email-test-suite-helper.sh [command] [options]`
- **Tools required**: dig, openssl, curl; optional: html-validate, mjml
- **Related**: `email-health-check-helper.sh` for DNS authentication checks

<!-- AI-CONTEXT-END -->

## Commands

```bash
# Design rendering (all checks including accessibility)
email-test-suite-helper.sh test-design newsletter.html
email-test-suite-helper.sh validate-html newsletter.html
email-test-suite-helper.sh check-css newsletter.html
email-test-suite-helper.sh check-dark-mode template.html
email-test-suite-helper.sh check-responsive campaign.html
email-test-suite-helper.sh check-accessibility newsletter.html
email-test-suite-helper.sh generate-test-email test.html

# Delivery testing
email-test-suite-helper.sh test-smtp smtp.gmail.com 587
email-test-suite-helper.sh test-smtp-domain example.com
email-test-suite-helper.sh analyze-headers headers.txt
email-test-suite-helper.sh check-placement example.com
email-test-suite-helper.sh test-tls mail.example.com 465
```

## What Each Check Covers

**Design rendering** (`test-design` runs all):

- **HTML Structure** — DOCTYPE, charset, viewport, table layout, inline styles, image alt text, file size (Gmail 102KB clip limit)
- **CSS Compatibility** — detects unsupported CSS (flexbox, grid, position, float, animations) that break in Outlook/Gmail/Yahoo
- **Dark Mode** — color-scheme meta, prefers-color-scheme queries, hardcoded colors, transparent PNGs
- **Responsive** — viewport meta, fixed widths, media queries, MSO conditionals, font sizes, touch targets
- **Accessibility** — WCAG 2.1 AA: alt text, lang attribute, table roles, font sizes, link text, headings, colour usage

**Delivery testing**:

- **SMTP** — TCP connection, SMTP banner, STARTTLS/TLS support
- **Header Analysis** — SPF/DKIM/DMARC results, delivery path, spam indicators, List-Unsubscribe
- **Inbox Placement** — scored 0–10 (see table below)
- **TLS** — certificate validity, expiry, TLS version

## Email Client Rendering Engines

| Engine | Clients | Key Limitations |
|--------|---------|-----------------|
| WebKit | Apple Mail, iOS Mail, Outlook macOS | Best CSS support |
| Blink | Gmail Web, Gmail Android | Strips `<style>` blocks, limited media queries |
| Word | Outlook 2016+, Outlook 365 | No flexbox/grid, limited CSS, VML for backgrounds |
| Custom | Yahoo, AOL, Thunderbird | Partial media query support |

## CSS Compatibility

| Property | Apple Mail | Gmail | Outlook | Yahoo |
|----------|-----------|-------|---------|-------|
| Flexbox | Yes | Yes | **No** | Yes |
| Grid | Yes | Yes | **No** | Partial |
| border-radius | Yes | Yes | **No** (images) | Yes |
| background-image | Yes | Yes | **VML only** | Yes |
| Media queries | Yes | **Partial** | **No** | **Partial** |
| Custom fonts | Yes | **No** | **No** | **No** |
| Animations | Yes | **No** | **No** | **No** |

## Dark Mode

| Client | Behaviour |
|--------|-----------|
| Apple Mail | Full inversion with `prefers-color-scheme` support |
| Gmail (iOS) | Partial inversion, respects `color-scheme` meta |
| Outlook (iOS/Android) | Full inversion, ignores `prefers-color-scheme` |
| Yahoo | No dark mode support |

Best practices: add `<meta name="color-scheme" content="light dark">`, add `@media (prefers-color-scheme: dark)` styles, avoid hardcoded white backgrounds, test logos on both light/dark, use borders/shadows on transparent PNGs.

## Inbox Placement Scoring (`check-placement`)

| Factor | Points |
|--------|--------|
| SPF (valid + enforcement) | 1 |
| DKIM (at least one selector) | 1 |
| DMARC quarantine/reject | 2 |
| DMARC none policy | 1 |
| MX records | 1 |
| Reverse DNS (PTR for MX IP) | 1 |
| MTA-STS | 1 |
| TLS-RPT | 1 |
| BIMI | 1 |
| Not blacklisted (Spamhaus) | 1 |

Score: 8–10 excellent · 6–7 good · 4–5 fair · 0–3 poor

## Recommended Workflow

```bash
email-health-check-helper.sh check example.com        # 1. DNS authentication
email-test-suite-helper.sh test-design newsletter.html # 2. Design + accessibility
email-test-suite-helper.sh check-placement example.com # 3. Delivery infrastructure
email-test-suite-helper.sh test-smtp-domain example.com # 4. SMTP connectivity
```

`email-health-check-helper.sh` focuses on DNS authentication (SPF/DKIM/DMARC) with graded scoring; `email-test-suite-helper.sh` covers design rendering and delivery infrastructure.

## External Testing Services

| Service | Purpose |
|---------|---------|
| Litmus | Visual rendering across 90+ clients |
| Email on Acid | Rendering + accessibility testing |
| Mailtrap | Email sandbox for development |
| mail-tester.com | Deliverability scoring (free) |
| Testi@ (testi.at) | Free email rendering preview |
| Google Postmaster | Gmail deliverability monitoring |
| Microsoft SNDS | Outlook/Hotmail reputation |

## Related

- `services/email/email-design-test.md` — Local Playwright rendering + Email on Acid API integration
- `services/email/email-health-check.md` — DNS authentication checks
- `services/email/ses.md` — Amazon SES integration
- `services/accessibility/accessibility-audit.md` — Email accessibility checks (WCAG compliance)
- `content/distribution/email.md` — Email content strategy
- `tools/accessibility/accessibility.md` — WCAG accessibility reference
- `tools/browser/browser-automation.md` — For automated rendering tests

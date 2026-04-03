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

## Quick Reference

- **Script**: `email-test-suite-helper.sh [command] [options]`
- **Required**: `dig`, `openssl`, `curl`; optional: `html-validate`, `mjml`
- **Related**: `email-health-check-helper.sh` (DNS auth), `email-design-test.md` (Playwright + Email on Acid API)

```bash
# Design rendering (HTML, CSS compat, dark mode, responsive, WCAG 2.1 AA)
email-test-suite-helper.sh test-design newsletter.html      # full suite
email-test-suite-helper.sh validate-html newsletter.html
email-test-suite-helper.sh check-css newsletter.html
email-test-suite-helper.sh check-dark-mode template.html
email-test-suite-helper.sh check-responsive campaign.html
email-test-suite-helper.sh check-accessibility newsletter.html
email-test-suite-helper.sh generate-test-email test.html

# Delivery (SMTP, TLS, headers, inbox placement)
email-test-suite-helper.sh test-smtp smtp.gmail.com 587
email-test-suite-helper.sh test-smtp-domain example.com     # auto-discover MX
email-test-suite-helper.sh analyze-headers headers.txt
email-test-suite-helper.sh check-placement example.com      # scored 0-10
email-test-suite-helper.sh test-tls smtp.example.com 587
```

## Recommended Workflow

```bash
email-health-check-helper.sh check example.com             # 1. DNS auth
email-test-suite-helper.sh test-design newsletter.html     # 2. Design rendering
email-test-suite-helper.sh check-placement example.com     # 3. Delivery infra
email-test-suite-helper.sh test-smtp-domain example.com    # 4. SMTP connectivity
email-health-check-helper.sh accessibility newsletter.html # 5. Standalone a11y
```

<!-- AI-CONTEXT-END -->

## Client Compatibility

| Engine | Clients | Flexbox/Grid | Media Queries | Custom Fonts | Notes |
|--------|---------|-------------|---------------|-------------|-------|
| **WebKit** | Apple Mail, iOS Mail, Outlook macOS | Yes | Yes | Yes | Best CSS support |
| **Blink** | Gmail Web, Gmail Android | Yes | Partial | No | Strips `<style>` blocks |
| **Word** | Outlook 2016+, Outlook 365 | No | No | No | VML for backgrounds; no `border-radius` on images |
| **Custom** | Yahoo, AOL, Thunderbird | Yes/Partial | Partial | No | Partial media query support |

## Dark Mode

| Client | Behavior |
|--------|----------|
| Apple Mail | Full inversion; `prefers-color-scheme` supported |
| Gmail (iOS) | Partial inversion; respects `color-scheme` meta |
| Outlook (iOS/Android) | Full inversion; ignores `prefers-color-scheme` |
| Yahoo | No dark mode support |

Use `<meta name="color-scheme" content="light dark">` + `@media (prefers-color-scheme: dark)`. Avoid hardcoded white backgrounds; test logos on light/dark; use borders/shadows on transparent PNGs.

## Inbox Placement Scoring

`check-placement` scores domains 0-10:

| Factor | Pts | Factor | Pts |
|--------|-----|--------|-----|
| SPF (valid, enforced) | 1 | Reverse DNS (PTR for MX IP) | 1 |
| DKIM (valid selector) | 1 | MTA-STS (TLS enforcement) | 1 |
| DMARC enforce (quarantine/reject) | 2 | TLS-RPT (reporting) | 1 |
| DMARC monitor (none) | 1 | BIMI (brand logo) | 1 |
| MX records (valid) | 1 | Not blacklisted (Spamhaus) | 1 |

**8-10** excellent | **6-7** good | **4-5** fair (some spam) | **0-3** poor

## External Testing Services

| Service | Purpose |
|---------|---------|
| [Litmus](https://litmus.com) | Visual rendering across 90+ clients |
| [Email on Acid](https://emailonacid.com) | Rendering + accessibility testing |
| [Mailtrap](https://mailtrap.io) | Email sandbox for development |
| [mail-tester.com](https://mail-tester.com) | Deliverability scoring (free) |
| [Testi@](https://testi.at) | Free email rendering preview |
| [Google Postmaster](https://postmaster.google.com) | Gmail deliverability monitoring |
| [Microsoft SNDS](https://sendersupport.olc.protection.outlook.com) | Outlook/Hotmail reputation |

## Related

- `services/email/email-design-test.md` — Playwright rendering + Email on Acid API
- `services/email/email-health-check.md` — DNS authentication
- `services/email/ses.md` — Amazon SES
- `content/distribution-email.md` — email content strategy
- `tools/accessibility/accessibility-audit.md` — email WCAG compliance
- `tools/browser/browser-automation.md` — automated rendering tests

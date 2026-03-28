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
- **Required tools**: `dig`, `openssl`, `curl`; optional: `html-validate`, `mjml`
- **Related**: `email-health-check-helper.sh` for DNS authentication checks

**Design rendering** (HTML validation, CSS compat, dark mode, responsive, accessibility — WCAG 2.1 AA):

```bash
email-test-suite-helper.sh test-design newsletter.html      # full suite
email-test-suite-helper.sh validate-html newsletter.html
email-test-suite-helper.sh check-css newsletter.html
email-test-suite-helper.sh check-dark-mode template.html
email-test-suite-helper.sh check-responsive campaign.html
email-test-suite-helper.sh check-accessibility newsletter.html
email-test-suite-helper.sh generate-test-email test.html
```

**Delivery** (SMTP, TLS, headers, inbox placement):

```bash
email-test-suite-helper.sh test-smtp smtp.gmail.com 587
email-test-suite-helper.sh test-smtp mail.example.com 25
email-test-suite-helper.sh test-smtp-domain example.com     # auto-discover MX
email-test-suite-helper.sh analyze-headers headers.txt
email-test-suite-helper.sh check-placement example.com      # scored 0-10
email-test-suite-helper.sh test-tls mail.example.com 465
email-test-suite-helper.sh test-tls smtp.example.com 587
```

<!-- AI-CONTEXT-END -->

## Email Client Rendering Engines

| Engine | Clients | Key Limitations |
|--------|---------|-----------------|
| **WebKit** | Apple Mail, iOS Mail, Outlook macOS | Best CSS support |
| **Blink** | Gmail Web, Gmail Android | Strips `<style>` blocks, limited media queries |
| **Word** | Outlook 2016+, Outlook 365 | No flexbox/grid, limited CSS, VML for backgrounds |
| **Custom** | Yahoo, AOL, Thunderbird | Partial media query support |

## CSS Compatibility

| CSS Property | Apple Mail | Gmail | Outlook | Yahoo |
|-------------|-----------|-------|---------|-------|
| Flexbox | Yes | Yes | **No** | Yes |
| Grid | Yes | Yes | **No** | Partial |
| border-radius | Yes | Yes | **No** (images) | Yes |
| background-image | Yes | Yes | **VML only** | Yes |
| Media queries | Yes | **Partial** | **No** | **Partial** |
| Custom fonts | Yes | **No** | **No** | **No** |
| Animations | Yes | **No** | **No** | **No** |

## Dark Mode

| Client | Behavior |
|--------|----------|
| Apple Mail | Full inversion with `prefers-color-scheme` support |
| Gmail (iOS) | Partial inversion, respects `color-scheme` meta |
| Outlook (iOS/Android) | Full inversion, ignores `prefers-color-scheme` |
| Yahoo | No dark mode support |

**Best practices:**

1. Add `<meta name="color-scheme" content="light dark">`
2. Add `@media (prefers-color-scheme: dark)` styles
3. Avoid hardcoded white backgrounds
4. Test logos on both light and dark backgrounds
5. Use borders/shadows on transparent PNGs

## Inbox Placement Scoring

`check-placement` scores domains 0–10:

| Factor | Points | Description |
|--------|--------|-------------|
| SPF | 1 | Valid SPF with enforcement |
| DKIM | 1 | At least one valid selector |
| DMARC (enforce) | 2 | quarantine or reject policy |
| DMARC (monitor) | 1 | none policy |
| MX records | 1 | Valid mail exchange records |
| Reverse DNS | 1 | PTR record for MX IP |
| MTA-STS | 1 | TLS enforcement configured |
| TLS-RPT | 1 | TLS reporting configured |
| BIMI | 1 | Brand logo configured |
| Not blacklisted | 1 | Clean on Spamhaus |

| Score | Interpretation |
|-------|---------------|
| 8–10 | Excellent — high inbox placement expected |
| 6–7 | Good — most emails reach inbox |
| 4–5 | Fair — some emails may go to spam |
| 0–3 | Poor — significant deliverability issues |

## Integration with Health Check

| Tool | Focus |
|------|-------|
| `email-health-check-helper.sh` | DNS authentication (SPF, DKIM, DMARC) with graded scoring |
| `email-test-suite-helper.sh` | Design rendering + delivery infrastructure |

**Recommended workflow:**

```bash
email-health-check-helper.sh check example.com             # 1. DNS auth
email-test-suite-helper.sh test-design newsletter.html     # 2. Design rendering
email-test-suite-helper.sh check-placement example.com     # 3. Delivery infra
email-test-suite-helper.sh test-smtp-domain example.com    # 4. SMTP connectivity
email-health-check-helper.sh accessibility newsletter.html # 5. Standalone a11y
```

## External Testing Services

| Service | Purpose | URL |
|---------|---------|-----|
| **Litmus** | Visual rendering across 90+ clients | litmus.com |
| **Email on Acid** | Rendering + accessibility testing | emailonacid.com |
| **Mailtrap** | Email sandbox for development | mailtrap.io |
| **mail-tester.com** | Deliverability scoring (free) | mail-tester.com |
| **Testi@** | Free email rendering preview | testi.at |
| **Google Postmaster** | Gmail deliverability monitoring | postmaster.google.com |
| **Microsoft SNDS** | Outlook/Hotmail reputation | sendersupport.olc.protection.outlook.com |

## Related

- `services/email/email-design-test.md` - Local Playwright rendering + Email on Acid API integration
- `tools/accessibility/accessibility-audit.md` - Email accessibility checks (WCAG compliance)
- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/ses.md` - Amazon SES integration
- `content/distribution/email.md` - Email content strategy
- `tools/accessibility/accessibility.md` - WCAG accessibility reference
- `tools/browser/browser-automation.md` - For automated rendering tests

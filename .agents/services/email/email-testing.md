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

- **Purpose**: Comprehensive email testing - design rendering, delivery, and inbox placement
- **Script**: `email-test-suite-helper.sh [command] [options]`
- **Checks**: HTML validation, CSS compatibility, dark mode, responsive design, SMTP, TLS, headers
- **Tools**: dig, openssl, curl (required); html-validate, mjml (optional)
- **Related**: `email-health-check-helper.sh` for DNS authentication checks

**Quick commands:**

```bash
# Design rendering tests
email-test-suite-helper.sh test-design newsletter.html
email-test-suite-helper.sh check-dark-mode template.html
email-test-suite-helper.sh check-responsive campaign.html

# Delivery testing
email-test-suite-helper.sh test-smtp smtp.gmail.com 587
email-test-suite-helper.sh test-smtp-domain example.com
email-test-suite-helper.sh check-placement example.com

# Header analysis
email-test-suite-helper.sh analyze-headers headers.txt

# Generate test template
email-test-suite-helper.sh generate-test-email test.html
```

<!-- AI-CONTEXT-END -->

## Overview

The email testing suite provides two categories of testing:

### 1. Design Rendering Tests

Validate that HTML emails render correctly across email clients:

- **HTML Structure** - DOCTYPE, charset, viewport, table layout, inline styles, image alt text, file size (Gmail 102KB clip limit)
- **CSS Compatibility** - Detects unsupported CSS (flexbox, grid, position, float, animations) that break in Outlook/Gmail/Yahoo
- **Dark Mode** - color-scheme meta, prefers-color-scheme queries, hardcoded colors, transparent PNGs
- **Responsive Design** - Viewport meta, fixed widths, media queries, MSO conditionals, font sizes, touch targets

### 2. Delivery Testing

Validate email delivery infrastructure:

- **SMTP Connectivity** - TCP connection, SMTP banner, STARTTLS/TLS support
- **Domain SMTP** - Auto-discover MX records and test primary mail server
- **Header Analysis** - Authentication results (SPF/DKIM/DMARC), delivery path, spam indicators, List-Unsubscribe
- **Inbox Placement** - Comprehensive scoring (SPF, DKIM, DMARC, MX, PTR, MTA-STS, TLS-RPT, BIMI, blacklists)
- **TLS Certificate** - Certificate validity, expiry, TLS version for mail servers

## Usage

### Design Rendering

```bash
# Full design test suite (all checks)
email-test-suite-helper.sh test-design newsletter.html

# Individual checks
email-test-suite-helper.sh validate-html newsletter.html
email-test-suite-helper.sh check-css newsletter.html
email-test-suite-helper.sh check-dark-mode newsletter.html
email-test-suite-helper.sh check-responsive newsletter.html

# Generate a test email template
email-test-suite-helper.sh generate-test-email test.html
```

### Delivery Testing

```bash
# Test SMTP server directly
email-test-suite-helper.sh test-smtp smtp.gmail.com 587
email-test-suite-helper.sh test-smtp mail.example.com 25

# Auto-discover and test domain's mail servers
email-test-suite-helper.sh test-smtp-domain example.com

# Analyze email headers (from file or stdin)
email-test-suite-helper.sh analyze-headers headers.txt

# Check inbox placement factors (scored)
email-test-suite-helper.sh check-placement example.com

# Test mail server TLS
email-test-suite-helper.sh test-tls mail.example.com 465
email-test-suite-helper.sh test-tls smtp.example.com 587
```

## Email Client Rendering Engines

Understanding which rendering engine each client uses helps predict compatibility:

| Engine | Clients | Key Limitations |
|--------|---------|-----------------|
| **WebKit** | Apple Mail, iOS Mail, Outlook macOS | Best CSS support |
| **Blink** | Gmail Web, Gmail Android | Strips `<style>` blocks, limited media queries |
| **Word** | Outlook 2016+, Outlook 365 | No flexbox/grid, limited CSS, VML for backgrounds |
| **Custom** | Yahoo, AOL, Thunderbird | Partial media query support |

## CSS Compatibility Quick Reference

| CSS Property | Apple Mail | Gmail | Outlook | Yahoo |
|-------------|-----------|-------|---------|-------|
| Flexbox | Yes | Yes | **No** | Yes |
| Grid | Yes | Yes | **No** | Partial |
| border-radius | Yes | Yes | **No** (images) | Yes |
| background-image | Yes | Yes | **VML only** | Yes |
| Media queries | Yes | **Partial** | **No** | **Partial** |
| Custom fonts | Yes | **No** | **No** | **No** |
| Animations | Yes | **No** | **No** | **No** |

## Dark Mode Testing

Email clients handle dark mode differently:

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

The `check-placement` command scores domains on a 10-point scale:

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

**Score interpretation:**

- **8-10**: Excellent - high inbox placement expected
- **6-7**: Good - most emails reach inbox
- **4-5**: Fair - some emails may go to spam
- **0-3**: Poor - significant deliverability issues

## Integration with Health Check

The email test suite complements `email-health-check-helper.sh`:

| Tool | Focus |
|------|-------|
| `email-health-check-helper.sh` | DNS authentication (SPF, DKIM, DMARC) with graded scoring |
| `email-test-suite-helper.sh` | Design rendering + delivery infrastructure |

**Recommended workflow:**

```bash
# 1. Check DNS authentication
email-health-check-helper.sh check example.com

# 2. Test design rendering
email-test-suite-helper.sh test-design newsletter.html

# 3. Check delivery infrastructure
email-test-suite-helper.sh check-placement example.com

# 4. Test SMTP connectivity
email-test-suite-helper.sh test-smtp-domain example.com
```

## External Testing Services

For visual rendering tests across real email clients:

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

- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/ses.md` - Amazon SES integration
- `content/distribution/email.md` - Email content strategy
- `tools/browser/browser-automation.md` - For automated rendering tests

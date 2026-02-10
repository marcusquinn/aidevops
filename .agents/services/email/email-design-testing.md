---
description: Email design testing - local validation and Email on Acid API integration
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

# Email Design Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Local email design validation + Email on Acid (EOA) API for real-client rendering
- **Script**: `email-design-test-helper.sh [command] [options]`
- **Local checks**: HTML structure, CSS compatibility, dark mode, responsive, accessibility, images, links, preheader
- **EOA API**: Real screenshots across 90+ email clients (Outlook, Gmail, Apple Mail, mobile, etc.)
- **Auth**: HTTP Basic Auth (API key + password) or sandbox mode (no credentials needed)
- **Related**: `email-test-suite-helper.sh` (delivery testing), `email-health-check-helper.sh` (DNS auth)

**Quick commands:**

```bash
# Local design tests (no API key needed)
email-design-test-helper.sh test newsletter.html

# EOA sandbox (no API key needed)
email-design-test-helper.sh eoa-sandbox newsletter.html "My Newsletter"

# Full EOA test (requires API key)
email-design-test-helper.sh eoa-test newsletter.html "Campaign" outlook16,gmail_chr26_win

# Check results
email-design-test-helper.sh eoa-results <test-id>
email-design-test-helper.sh eoa-poll <test-id>

# List available clients
email-design-test-helper.sh eoa-clients
```

<!-- AI-CONTEXT-END -->

## Overview

The email design test helper provides two testing modes:

### 1. Local Design Testing

Fast, offline validation that catches common email design issues:

- **HTML Structure** - DOCTYPE, charset, viewport, table layout, inline styles, image alt text, file size
- **CSS Compatibility** - Detects unsupported CSS (flexbox, grid, position, float, animations)
- **Dark Mode** - color-scheme meta, prefers-color-scheme queries, hardcoded colors
- **Responsive Design** - Viewport meta, fixed widths, media queries, MSO conditionals
- **Accessibility** - lang attribute, role="presentation", title tag, semantic headings, color contrast
- **Image Optimization** - Dimensions, display:block, WebP/SVG warnings, retina handling
- **Link Validation** - Empty hrefs, javascript: links, HTTP vs HTTPS, UTM tracking
- **Preheader Text** - Hidden preview text detection

### 2. Email on Acid (EOA) API Testing

Submit HTML to EOA for real-client rendering screenshots across 90+ email clients:

- **Application clients** - Outlook 2016/2019/365, Apple Mail, Thunderbird
- **Mobile clients** - iPhone, iPad, Android (Gmail, Samsung Mail)
- **Web clients** - Gmail, Yahoo, Outlook.com, AOL (Chrome, Firefox, Edge)
- **Image blocking** - Test with images disabled
- **Spam testing** - Optional spam filter checks

## Setup

### EOA API Credentials

```bash
# Encrypted (recommended)
aidevops secret set EOA_API_KEY
aidevops secret set EOA_API_PASSWORD

# Or plaintext fallback (~/.config/aidevops/credentials.sh)
EOA_API_KEY="your-api-key"
EOA_API_PASSWORD="your-password"

# Or environment variables
export EOA_API_KEY="your-api-key"
export EOA_API_PASSWORD="your-password"
```

### Sandbox Mode

No credentials needed. Uses EOA's built-in sandbox for testing API integration without consuming test credits.

```bash
email-design-test-helper.sh eoa-sandbox newsletter.html
```

## Usage

### Local Testing

```bash
# Full local design test suite
email-design-test-helper.sh test newsletter.html
```

### EOA API Testing

```bash
# Full workflow: local tests + EOA submission + poll for results
email-design-test-helper.sh eoa-test newsletter.html "Subject Line"

# With specific clients
email-design-test-helper.sh eoa-test newsletter.html "Subject" outlook16,gmail_chr26_win,iphone6p_9

# Create test only (no polling)
email-design-test-helper.sh eoa-create newsletter.html "Subject"

# Poll for results
email-design-test-helper.sh eoa-poll <test-id>

# Get results
email-design-test-helper.sh eoa-results <test-id>
email-design-test-helper.sh eoa-results <test-id> outlook16  # specific client

# Reprocess failed screenshots
email-design-test-helper.sh eoa-reprocess <test-id> outlook16,gmail_chr26_win

# Get inlined CSS version
email-design-test-helper.sh eoa-inline-css <test-id>
```

### Client Management

```bash
# List all available clients
email-design-test-helper.sh eoa-clients

# Show default client list
email-design-test-helper.sh eoa-defaults

# List recent tests
email-design-test-helper.sh eoa-list

# Delete a test
email-design-test-helper.sh eoa-delete <test-id>
```

## EOA API Reference

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v5/auth` | GET | Test authentication |
| `/v5/email/clients` | GET | List available clients |
| `/v5/email/clients/default` | GET/PUT | Get/set default clients |
| `/v5/email/tests` | POST | Create email test |
| `/v5/email/tests` | GET | List all tests |
| `/v5/email/tests/<id>` | GET | Get test info/status |
| `/v5/email/tests/<id>` | DELETE | Delete test |
| `/v5.0.1/email/tests/<id>/results` | GET | Get results (with full thumbnails) |
| `/v5/email/tests/<id>/results/reprocess` | PUT | Reprocess screenshots |
| `/v5/email/tests/<id>/content/inlinecss` | GET | Get inlined CSS content |

## Recommended Workflow

```bash
# 1. Run local design tests first (fast, free)
email-design-test-helper.sh test newsletter.html

# 2. Fix any issues found locally

# 3. Submit to EOA for real-client rendering
email-design-test-helper.sh eoa-test newsletter.html "Final Campaign"

# 4. Review screenshots, fix issues, retest

# 5. Check DNS authentication
email-health-check-helper.sh check example.com

# 6. Check delivery infrastructure
email-test-suite-helper.sh check-placement example.com
```

## Integration with Other Email Tools

| Tool | Focus |
|------|-------|
| `email-design-test-helper.sh` | Design validation + real-client rendering (this tool) |
| `email-test-suite-helper.sh` | Design rendering + delivery infrastructure |
| `email-health-check-helper.sh` | DNS authentication (SPF, DKIM, DMARC) with graded scoring |

## Related

- `services/email/email-testing.md` - Email testing suite documentation
- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/ses.md` - Amazon SES integration
- `content/distribution/email.md` - Email content strategy
- `tools/accessibility/accessibility.md` - Accessibility testing

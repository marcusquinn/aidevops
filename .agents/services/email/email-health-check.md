---
description: Check email deliverability health and content quality (SPF, DKIM, DMARC, MX, blacklists, content precheck)
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

# Email Health Check

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate email authentication, deliverability, and content quality
- **Script**: `email-health-check-helper.sh [command] [domain|file]`
- **Infrastructure checks**: SPF, DKIM, DMARC, MX, blacklist, BIMI, MTA-STS, TLS-RPT, DANE, rDNS
- **Content checks**: Subject line, preheader, accessibility, links, images, spam words
- **Tools**: checkdmarc (Python CLI), dig/nslookup, mxtoolbox.com
- **Install**: `pip install checkdmarc` or `pipx install checkdmarc`

**Quick commands:**

```bash
# Full infrastructure health check
email-health-check-helper.sh check example.com

# Full content precheck (HTML email file)
email-health-check-helper.sh content-check newsletter.html

# Combined precheck (infrastructure + content)
email-health-check-helper.sh precheck example.com newsletter.html

# Individual infrastructure checks
email-health-check-helper.sh spf example.com
email-health-check-helper.sh dkim example.com selector1
email-health-check-helper.sh dmarc example.com
email-health-check-helper.sh mx example.com
email-health-check-helper.sh blacklist example.com

# Individual content checks
email-health-check-helper.sh check-subject newsletter.html
email-health-check-helper.sh check-preheader newsletter.html
email-health-check-helper.sh check-accessibility newsletter.html
email-health-check-helper.sh check-links newsletter.html
email-health-check-helper.sh check-images newsletter.html
email-health-check-helper.sh check-spam-words newsletter.html
```

<!-- AI-CONTEXT-END -->

## Overview

Email health checks validate that a domain is properly configured for email deliverability. This includes:

1. **SPF (Sender Policy Framework)** - Authorizes mail servers to send on behalf of domain
2. **DKIM (DomainKeys Identified Mail)** - Cryptographic signature for email authenticity
3. **DMARC (Domain-based Message Authentication)** - Policy for handling failed SPF/DKIM
4. **MX Records** - Mail exchange servers for receiving email
5. **Blacklist Status** - Check if domain/IP is on spam blacklists

## Installation

### checkdmarc (Recommended)

```bash
# Using pip
pip install checkdmarc

# Using pipx (isolated environment)
pipx install checkdmarc

# Verify installation
checkdmarc --version
```

### Alternative: Manual DNS Queries

If checkdmarc is not available, use dig/nslookup:

```bash
# SPF record
dig TXT example.com +short | grep spf

# DKIM record (requires selector)
dig TXT selector1._domainkey.example.com +short

# DMARC record
dig TXT _dmarc.example.com +short

# MX records
dig MX example.com +short
```

## Usage

### Full Health Check

```bash
# Run comprehensive check
./.agents/scripts/email-health-check-helper.sh check example.com

# Output includes:
# - SPF record and validity
# - DKIM status (common selectors)
# - DMARC policy and settings
# - MX records and priorities
# - Blacklist status summary
```

### Individual Checks

```bash
# SPF only
./.agents/scripts/email-health-check-helper.sh spf example.com

# DKIM with specific selector
./.agents/scripts/email-health-check-helper.sh dkim example.com google
./.agents/scripts/email-health-check-helper.sh dkim example.com selector1
./.agents/scripts/email-health-check-helper.sh dkim example.com k1  # Mailchimp

# DMARC only
./.agents/scripts/email-health-check-helper.sh dmarc example.com

# MX records
./.agents/scripts/email-health-check-helper.sh mx example.com

# Blacklist check
./.agents/scripts/email-health-check-helper.sh blacklist example.com
```

### Using checkdmarc Directly

```bash
# Basic check
checkdmarc example.com

# JSON output
checkdmarc example.com --json

# Check multiple domains
checkdmarc example.com example.org example.net

# Include DKIM check with selector
checkdmarc example.com --dkim-selector google

# Timeout settings
checkdmarc example.com --timeout 10
```

## Common DKIM Selectors

Different email providers use different DKIM selectors:

| Provider | Selector(s) |
|----------|-------------|
| Google Workspace | `google`, `google1`, `google2` |
| Microsoft 365 | `selector1`, `selector2` |
| Amazon SES | `*._domainkey` (varies) |
| Mailchimp | `k1`, `k2`, `k3` |
| SendGrid | `s1`, `s2`, `smtpapi` |
| Postmark | `pm`, `pm2` |
| Mailgun | `smtp`, `mailo`, `k1` |
| Zoho | `zoho`, `zmail` |

## Interpreting Results

### SPF Record

```text
v=spf1 include:_spf.google.com include:amazonses.com ~all
```

- `v=spf1` - SPF version (required)
- `include:` - Authorized sending domains
- `~all` - Soft fail (recommended)
- `-all` - Hard fail (strict)
- `?all` - Neutral (not recommended)

**Issues:**
- Missing SPF record = emails may be rejected
- Too many DNS lookups (>10) = SPF permerror
- `+all` = anyone can send (very bad)

### DKIM Record

```text
v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQ...
```

- `v=DKIM1` - DKIM version
- `k=rsa` - Key type
- `p=` - Public key (base64)

**Issues:**
- Missing DKIM = reduced deliverability
- Invalid key = signature verification fails
- Key too short (<1024 bits) = security risk

### DMARC Record

```text
v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com; pct=100
```

- `v=DMARC1` - DMARC version
- `p=` - Policy: `none`, `quarantine`, `reject`
- `rua=` - Aggregate report destination
- `ruf=` - Forensic report destination
- `pct=` - Percentage of messages to apply policy

**Recommended progression:**
1. Start with `p=none` to monitor
2. Move to `p=quarantine` after review
3. Eventually `p=reject` for full protection

### MX Records

```text
10 mail.example.com
20 backup.example.com
```

- Lower priority number = higher preference
- Multiple MX records provide redundancy

**Issues:**
- Missing MX = cannot receive email
- Unreachable MX servers = delivery failures
- Misconfigured priorities = routing issues

### Blacklist Status

Common blacklists checked:
- Spamhaus (ZEN, SBL, XBL, PBL)
- Barracuda
- SORBS
- SpamCop
- UCEPROTECT

**If blacklisted:**
1. Identify the cause (compromised account, spam complaints)
2. Fix the underlying issue
3. Request delisting from each blacklist

## Troubleshooting

### SPF Issues

```bash
# Check SPF record
dig TXT example.com +short | grep spf

# Count DNS lookups (must be ≤10)
# Each include:, a:, mx:, ptr:, exists: counts as 1 lookup

# Flatten SPF to reduce lookups
# Use tools like spf-flattener or manually expand includes
```

### DKIM Issues

```bash
# Find DKIM selector from email headers
# Look for: DKIM-Signature: ... s=selector; d=example.com

# Test specific selector
dig TXT selector._domainkey.example.com +short

# Common issue: selector mismatch between DNS and email config
```

### DMARC Issues

```bash
# Check DMARC record
dig TXT _dmarc.example.com +short

# Common issues:
# - Missing rua= means no reports
# - p=none provides no protection
# - Subdomain policy (sp=) may differ from main policy
```

## Integration with Other Tools

### mail-tester.com

For comprehensive deliverability testing:

1. Get test address from mail-tester.com
2. Send test email from your domain
3. Check score and recommendations

```bash
# The helper script can guide you through this
./.agents/scripts/email-health-check-helper.sh mail-tester
```

### mxtoolbox.com

For detailed diagnostics:

```bash
# Open MX Toolbox for domain
open "https://mxtoolbox.com/SuperTool.aspx?action=mx:example.com"

# Or use their API (requires account)
```

## Best Practices

### Minimum Requirements

1. **SPF**: Valid record with appropriate includes
2. **DKIM**: At least one valid DKIM key
3. **DMARC**: Policy set (even if `p=none` initially)
4. **MX**: At least one reachable mail server

### Recommended Setup

1. **SPF**: Include all legitimate senders, end with `~all` or `-all`
2. **DKIM**: 2048-bit keys, rotate annually
3. **DMARC**: `p=quarantine` or `p=reject` with reporting enabled
4. **Monitoring**: Regular checks and DMARC report analysis

### Monitoring Schedule

| Check | Frequency |
|-------|-----------|
| Full health check | Weekly |
| Blacklist status | Daily (automated) |
| DMARC reports | Weekly review |
| DKIM key rotation | Annually |

## Enhanced Checks (v2)

The health check now includes additional checks beyond the core SPF/DKIM/DMARC/MX/blacklist:

| Check | Purpose | Score |
|-------|---------|-------|
| **BIMI** | Brand logo display in inbox | 1 pt |
| **MTA-STS** | TLS enforcement for inbound mail | 1 pt |
| **TLS-RPT** | TLS failure reporting | 1 pt |
| **DANE/TLSA** | Cryptographic TLS verification | 1 pt |
| **Reverse DNS** | PTR record for mail server | 1 pt |

## Content-Level Checks (v3)

Inspired by [Email on Acid Campaign Precheck](https://www.emailonacid.com/features/), the health check now includes content-level validation for HTML email files. These checks catch issues that hurt open rates, engagement, and deliverability before you hit send.

### Content Check Commands

```bash
# Full content precheck (all content checks)
email-health-check-helper.sh content-check newsletter.html

# Individual content checks
email-health-check-helper.sh check-subject newsletter.html
email-health-check-helper.sh check-preheader newsletter.html
email-health-check-helper.sh check-accessibility newsletter.html
email-health-check-helper.sh check-links newsletter.html
email-health-check-helper.sh check-images newsletter.html
email-health-check-helper.sh check-spam-words newsletter.html
```

### Content Check Categories

| Check | What It Does | Score |
|-------|-------------|-------|
| **Subject Line** | Length (under 50 chars), ALL CAPS, excessive punctuation, emoji count, spam trigger words | 2 pts |
| **Preheader Text** | Presence, length (40-130 chars), not duplicating subject line | 1 pt |
| **Accessibility** | Alt text on images, lang attribute, semantic structure, color contrast hints, role attributes | 2 pts |
| **Link Validation** | Broken links, missing href, tracking parameters, unsubscribe link present, excessive links | 2 pts |
| **Image Validation** | Missing images, oversized files (>200KB), missing dimensions, total image weight, image-to-text ratio | 2 pts |
| **Spam Word Scan** | Scans subject, preheader, and body for words/phrases that trigger spam filters | 1 pt |

### Subject Line Analysis

The subject line check validates:

- **Length**: Warns if over 50 characters (mobile truncation), errors if over 80
- **ALL CAPS**: Flags subjects with >50% uppercase (spam filter trigger)
- **Punctuation**: Flags excessive `!` or `?` (more than 1 of each)
- **Spam triggers**: Checks against common spam words (`free`, `act now`, `limited time`, `click here`, `buy now`, `order now`, `100%`, `no obligation`, etc.)
- **Empty subject**: Errors if no `<title>` tag or subject line found

### Preheader Text Analysis

The preheader check validates:

- **Presence**: Warns if no preheader/preview text is defined
- **Length**: Optimal range is 40-130 characters (too short wastes space, too long gets truncated)
- **Duplication**: Flags if preheader duplicates the subject line
- **Default text**: Flags common placeholder text ("View in browser", "Email not displaying correctly")

### Accessibility Checks

Based on ADA/WCAG email compliance:

- **Image alt text**: Every `<img>` must have an `alt` attribute (decorative images use `alt=""`)
- **Language attribute**: `<html lang="en">` (or appropriate language) must be present
- **Semantic headings**: Checks for proper heading hierarchy (h1 → h2 → h3)
- **Table roles**: Layout tables should have `role="presentation"`
- **Link text**: Flags generic link text ("click here", "read more") without context
- **Font size**: Warns if body text is below 14px (readability)

### Link Validation

- **Empty hrefs**: Flags `<a>` tags with empty or missing `href`
- **Placeholder links**: Detects `#`, `javascript:`, or placeholder URLs
- **Unsubscribe link**: Verifies at least one unsubscribe/opt-out link exists (CAN-SPAM requirement)
- **Link count**: Warns if more than 20 links (spam filter trigger)
- **Tracking parameters**: Informational — reports UTM parameters found

### Image Validation

- **Missing alt text**: Cross-referenced with accessibility check
- **File size**: Warns if any single image exceeds 200KB (slow loading)
- **Total weight**: Warns if total image weight exceeds 800KB
- **Missing dimensions**: Flags images without `width`/`height` attributes (causes layout shift)
- **Image-to-text ratio**: Warns if email is >60% images (spam filter trigger, accessibility issue)
- **External images**: Reports count of externally-hosted images

### Spam Word Scanner

Scans email content for words and phrases known to trigger spam filters:

**High-risk words** (subject line): `free`, `act now`, `limited time`, `click here`, `buy now`, `order now`, `100% free`, `no obligation`, `risk free`, `winner`, `congratulations`, `urgent`, `cash`, `guarantee`

**Medium-risk words** (body): `unsubscribe` (without actual link), `dear friend`, `once in a lifetime`, `as seen on`, `double your`, `earn money`, `no cost`, `special promotion`

**Scoring**: Each high-risk word in the subject deducts 0.5 points. Each medium-risk word in the body deducts 0.25 points. Minimum score is 0.

### Full Precheck (Domain + Content)

Run both infrastructure and content checks together:

```bash
# Full precheck: domain health + content validation
email-health-check-helper.sh precheck example.com newsletter.html

# Output includes:
# - All DNS/infrastructure checks (SPF, DKIM, DMARC, etc.)
# - All content checks (subject, preheader, accessibility, etc.)
# - Combined score out of 25 with letter grade
```

**Full precheck** produces a combined health score (out of 25) with letter grade:

```bash
email-health-check-helper.sh precheck example.com newsletter.html
# Infrastructure: 12/15 (80%) - Grade: B
# Content:        8/10 (80%) - Grade: B
# Combined:      20/25 (80%) - Grade: B
```

## Related

- `services/email/email-testing.md` - Design rendering and delivery testing
- `services/email/ses.md` - Amazon SES integration
- `services/hosting/dns.md` - DNS management
- `content/distribution/email.md` - Email content strategy and best practices
- `tools/browser/browser-automation.md` - For mail-tester automation

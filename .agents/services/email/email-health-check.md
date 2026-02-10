---
description: Check email deliverability health (SPF, DKIM, DMARC, MX, blacklists)
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

- **Purpose**: Validate email authentication and deliverability for domains
- **Script**: `email-health-check-helper.sh [command] [domain]`
- **Checks**: SPF, DKIM, DMARC, MX records, blacklist status
- **Tools**: checkdmarc (Python CLI), dig/nslookup, mxtoolbox.com
- **Install**: `pip install checkdmarc` or `pipx install checkdmarc`

**Quick commands:**

```bash
# Full health check
email-health-check-helper.sh check example.com

# Individual checks
email-health-check-helper.sh spf example.com
email-health-check-helper.sh dkim example.com selector1
email-health-check-helper.sh dmarc example.com
email-health-check-helper.sh mx example.com
email-health-check-helper.sh blacklist example.com

# Email accessibility audit (WCAG 2.1)
email-health-check-helper.sh accessibility newsletter.html
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

**Full check** now produces a health score (out of 15) with letter grade:

```bash
email-health-check-helper.sh check example.com
# Score: 12/15 (80%) - Grade: B
```

## Email Accessibility

The health check now includes an `accessibility` command for auditing HTML email templates against WCAG 2.1 AA (email-applicable subset):

```bash
email-health-check-helper.sh accessibility newsletter.html
```

This delegates to `accessibility-helper.sh email` and checks:

- Images without `alt` attributes (WCAG 1.1.1)
- Missing `lang` attribute on `<html>` (WCAG 3.1.1)
- Layout tables without `role="presentation"` (WCAG 1.3.1)
- Small font sizes below 12px (WCAG 1.4.4)
- Generic link text like "click here" (WCAG 2.4.4)
- Heading structure (WCAG 1.3.1)
- Colour-only information indicators (WCAG 1.4.1)

For contrast ratio checks, use: `accessibility-helper.sh contrast '#fg' '#bg'`

## Related

- `services/email/email-testing.md` - Design rendering and delivery testing
- `services/email/ses.md` - Amazon SES integration
- `services/hosting/dns.md` - DNS management
- `tools/accessibility/accessibility.md` - WCAG accessibility reference
- `services/accessibility/accessibility-audit.md` - Full accessibility audit service
- `tools/browser/browser-automation.md` - For mail-tester automation

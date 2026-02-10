---
description: Email deliverability testing - spam analysis, provider checks, inbox placement
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

# Email Delivery Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Spam content analysis, provider-specific deliverability, inbox placement testing
- **Script**: `email-delivery-test-helper.sh [command] [options]`
- **Checks**: Spam triggers, Gmail/Outlook/Yahoo deliverability, seed-list placement, warm-up
- **Tools**: dig, openssl, curl, nc (required); swaks, spamassassin (optional)
- **Related**: `email-health-check-helper.sh` (DNS auth), `email-test-suite-helper.sh` (design rendering)

**Quick commands:**

```bash
# Spam content analysis
email-delivery-test-helper.sh spam-check newsletter.html

# Provider-specific deliverability
email-delivery-test-helper.sh gmail example.com
email-delivery-test-helper.sh outlook example.com
email-delivery-test-helper.sh providers example.com

# Inbox placement
email-delivery-test-helper.sh seed-test example.com
email-delivery-test-helper.sh send-test me@example.com test@gmail.com smtp.example.com

# Warm-up guidance
email-delivery-test-helper.sh warmup example.com

# Full report
email-delivery-test-helper.sh report example.com
```

<!-- AI-CONTEXT-END -->

## Overview

The email delivery test helper focuses on three areas that complement the existing email tools:

### 1. Spam Content Analysis

Analyses email HTML/text for content-level spam signals:

- **Subject line** - ALL CAPS, excessive punctuation, financial/prize language
- **High-risk phrases** - "act now", "buy now", "click here", "free gift", etc.
- **Medium-risk phrases** - "bargain", "discount", "exclusive deal", etc.
- **Structural signals** - Image-to-text ratio, URL count, shortened URLs, hidden text, JavaScript, form elements
- **Compliance** - Unsubscribe link, physical address (CAN-SPAM)

Produces a spam score (0-100) with risk rating: CLEAN, LOW RISK, MEDIUM RISK, HIGH RISK, CRITICAL.

### 2. Provider-Specific Deliverability

Checks deliverability requirements for each major email provider:

**Gmail** (8-point score):

- SPF, DKIM, DMARC enforcement
- One-click unsubscribe (Feb 2024 requirement)
- PTR records, Google Postmaster Tools, ARC headers

**Outlook** (7-point score):

- SPF, DKIM, DMARC
- MTA-STS support
- Blacklist status, Microsoft SNDS

**Yahoo/AOL** (5-point score):

- SPF, DKIM, DMARC enforcement
- One-click unsubscribe (Feb 2024 requirement)

### 3. Inbox Placement & Warm-Up

- **Seed-list testing** - Guide for manual and automated inbox placement testing
- **SMTP send test** - Send test emails via swaks or openssl
- **Warm-up schedule** - Day-by-day volume ramp-up for new IPs/domains
- **Monitoring services** - Links to Google Postmaster, Microsoft SNDS, etc.

## Usage

### Spam Content Analysis

```bash
# Analyse email HTML for spam triggers
email-delivery-test-helper.sh spam-check newsletter.html

# Use SpamAssassin if installed
email-delivery-test-helper.sh spamassassin newsletter.html
```

### Provider Deliverability

```bash
# Check all providers
email-delivery-test-helper.sh providers example.com

# Individual providers
email-delivery-test-helper.sh gmail example.com
email-delivery-test-helper.sh outlook example.com
email-delivery-test-helper.sh yahoo example.com
```

### Inbox Placement

```bash
# Seed-list testing guide
email-delivery-test-helper.sh seed-test example.com

# Send test email via SMTP
email-delivery-test-helper.sh send-test me@example.com test@gmail.com smtp.example.com 587
```

### Warm-Up

```bash
# View warm-up schedule and guidance
email-delivery-test-helper.sh warmup example.com
```

### Full Report

```bash
# Comprehensive deliverability report
email-delivery-test-helper.sh report example.com
```

## Spam Score Interpretation

| Score | Rating | Meaning |
|-------|--------|---------|
| 0-10 | CLEAN | Unlikely to trigger spam filters |
| 11-25 | LOW RISK | Minor issues, should pass most filters |
| 26-50 | MEDIUM RISK | May trigger filters in some providers |
| 51-75 | HIGH RISK | Likely to be flagged as spam |
| 76-100 | CRITICAL | Will almost certainly be flagged |

## Feb 2024 Bulk Sender Requirements

Gmail and Yahoo introduced strict requirements for bulk senders (>5000 emails/day):

| Requirement | Gmail | Yahoo |
|-------------|-------|-------|
| SPF | Required | Required |
| DKIM | Required | Required |
| DMARC (p=quarantine+) | Required | Required |
| One-click unsubscribe | Required | Required |
| Spam rate < 0.3% | Required | Required |
| PTR records | Required | Recommended |

## Warm-Up Schedule

For new IPs/domains, follow this gradual volume increase:

| Day | Daily Volume | Notes |
|-----|-------------|-------|
| 1-2 | 50 | Most engaged contacts only |
| 3-4 | 100 | Monitor bounce/complaint rates |
| 5-6 | 250 | Check Google Postmaster Tools |
| 7-8 | 500 | Review inbox placement |
| 9-10 | 1,000 | Expand to broader audience |
| 11-14 | 2,500 | Continue monitoring |
| 15-21 | 5,000 | Steady increase |
| 22-28 | 10,000 | Approaching normal volume |
| 29+ | 25,000+ | Full volume (if metrics healthy) |

## Integration with Other Email Tools

| Tool | Focus |
|------|-------|
| `email-health-check-helper.sh` | DNS authentication (SPF, DKIM, DMARC) with graded scoring |
| `email-test-suite-helper.sh` | Design rendering + delivery infrastructure |
| `email-delivery-test-helper.sh` | Spam content + provider deliverability + inbox placement |

**Recommended workflow:**

```bash
# 1. Check DNS authentication
email-health-check-helper.sh check example.com

# 2. Analyse content for spam triggers
email-delivery-test-helper.sh spam-check newsletter.html

# 3. Check provider-specific deliverability
email-delivery-test-helper.sh providers example.com

# 4. Test design rendering
email-test-suite-helper.sh test-design newsletter.html

# 5. Send test emails
email-delivery-test-helper.sh send-test me@example.com test@gmail.com
```

## External Services

| Service | Purpose | URL |
|---------|---------|-----|
| **Google Postmaster** | Gmail reputation monitoring | postmaster.google.com |
| **Microsoft SNDS** | Outlook reputation monitoring | sendersupport.olc.protection.outlook.com |
| **mail-tester.com** | Deliverability scoring (free) | mail-tester.com |
| **GlockApps** | Inbox placement testing | glockapps.com |
| **Mailtrap** | Email sandbox | mailtrap.io |
| **Mailreach** | Warm-up automation | mailreach.co |
| **InboxAlly** | Warm-up automation | inboxally.com |

## Related

- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/email-testing.md` - Design rendering and delivery testing
- `services/email/ses.md` - Amazon SES integration
- `content/distribution/email.md` - Email content strategy

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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Email Health Check

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate email authentication, deliverability, and content quality
- **Script**: `email-health-check-helper.sh [command] [domain|file]`
- **Infrastructure checks**: SPF, DKIM, DMARC, MX, blacklist, BIMI, MTA-STS, TLS-RPT, DANE, rDNS
- **Content checks**: Subject line, preheader, accessibility, links, images, spam words
- **Tools**: checkdmarc (`pip install checkdmarc` or `pipx install checkdmarc`), dig/nslookup, mxtoolbox.com

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

# Email accessibility audit (WCAG 2.1)
email-health-check-helper.sh accessibility newsletter.html
```

<!-- AI-CONTEXT-END -->

## Common DKIM Selectors

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

## Record Reference

| Record | Key fields | Common issues |
|--------|-----------|---------------|
| **SPF** | `v=spf1 include:… ~all` (`-all` strict, `?all` neutral) | Missing record; >10 DNS lookups (permerror); `+all` (anyone can send) |
| **DKIM** | `v=DKIM1; k=rsa; p=<pubkey>` | Missing record; invalid/short key (<1024 bits) |
| **DMARC** | `v=DMARC1; p=quarantine; rua=mailto:…; pct=100` | `p=none` (no protection); missing `rua=` (no reports); subdomain `sp=` differs |
| **MX** | `10 mail.example.com` (lower = higher priority) | Missing record; unreachable servers |
| **Blacklists** | Spamhaus ZEN/SBL/XBL/PBL, Barracuda, SORBS, SpamCop, UCEPROTECT | Identify cause → fix → request delisting |

**DMARC progression**: `p=none` (monitor) → `p=quarantine` → `p=reject`

## Best Practices

| Check | Frequency | Notes |
|-------|-----------|-------|
| Full health check | Weekly | Minimum: valid SPF, DKIM, DMARC `p=quarantine`+, one reachable MX |
| Blacklist status | Daily (automated) | |
| DMARC reports | Weekly review | Recommended: SPF `~all`/`-all`; DKIM 2048-bit rotated annually |
| DKIM key rotation | Annually | |

## Enhanced Checks (v2)

| Check | Purpose | Score |
|-------|---------|-------|
| **BIMI** | Brand logo display in inbox | 1 pt |
| **MTA-STS** | TLS enforcement for inbound mail | 1 pt |
| **TLS-RPT** | TLS failure reporting | 1 pt |
| **DANE/TLSA** | Cryptographic TLS verification | 1 pt |
| **Reverse DNS** | PTR record for mail server | 1 pt |

## Content-Level Checks (v3)

| Check | What It Does | Score |
|-------|-------------|-------|
| **Subject Line** | Length (under 50 chars), ALL CAPS, excessive punctuation, spam trigger words | 2 pts |
| **Preheader Text** | Presence, length (40-130 chars), not duplicating subject line | 1 pt |
| **Accessibility** | Alt text, lang attribute, semantic structure, color contrast, role attributes. Delegates to `accessibility-helper.sh email` (WCAG 2.1 AA). Contrast: `accessibility-helper.sh contrast '#fg' '#bg'` | 2 pts |
| **Link Validation** | Broken links, missing href, unsubscribe link present (CAN-SPAM), excessive links (>20) | 2 pts |
| **Image Validation** | Oversized files (>200KB), missing dimensions, total weight (>800KB), image-to-text ratio (>60%) | 2 pts |
| **Spam Word Scan** | High-risk subject words (`free`, `act now`, `click here`, `guarantee`, etc.); medium-risk body words | 1 pt |

**Scoring**: High-risk subject word = −0.5 pts; medium-risk body word = −0.25 pts. Combined precheck score out of 25 with letter grade.

```bash
email-health-check-helper.sh precheck example.com newsletter.html
# Infrastructure: 12/15 (80%) - Grade: B
# Content:        8/10 (80%) - Grade: B
# Combined:      20/25 (80%) - Grade: B
```

## Related

- `tools/accessibility/accessibility-audit.md` - Email accessibility checks (WCAG compliance)
- `services/email/email-testing.md` - Design rendering and delivery testing
- `services/email/ses.md` - Amazon SES integration
- `services/hosting/dns.md` - DNS management
- `content/distribution-email.md` - Email content strategy and best practices
- `tools/accessibility/accessibility.md` - WCAG accessibility reference
- `tools/browser/browser-automation.md` - For mail-tester automation

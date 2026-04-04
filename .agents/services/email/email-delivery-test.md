---
description: Spam filter testing, inbox placement verification, and content deliverability analysis
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

# Email Delivery Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Test emails against spam filters, verify inbox placement, analyze content deliverability
- **Scripts**: `email-test-suite-helper.sh check-placement [domain]`, `email-health-check-helper.sh check [domain]`
- **Focus**: Content-level spam triggers, provider-specific filtering, seed list testing, reputation signals
- **Complements**: `email-health-check.md` (DNS auth), `email-testing.md` (design rendering + infrastructure)

```bash
email-test-suite-helper.sh check-placement example.com   # Inbox placement score
email-health-check-helper.sh check example.com           # DNS authentication health
email-test-suite-helper.sh test-smtp-domain example.com  # SMTP delivery test
email-test-suite-helper.sh analyze-headers headers.txt   # Header analysis (spam verdicts)
```

<!-- AI-CONTEXT-END -->

## Testing Workflow

```bash
# 1. DNS and authentication
email-health-check-helper.sh check example.com

# 2. Infrastructure and placement score
email-test-suite-helper.sh check-placement example.com

# 3. SMTP connectivity
email-test-suite-helper.sh test-smtp-domain example.com

# 4. Design rendering (if HTML email)
email-test-suite-helper.sh test-design newsletter.html

# 5. Send to mail-tester.com (manual — send real email, check score)

# 6. Send to seed accounts (manual — check inbox vs spam placement)

# 7. Analyze headers from spam-folder copies
email-test-suite-helper.sh analyze-headers spam-headers.txt

# 8. Monitor post-send: Google Postmaster Tools, Microsoft SNDS, ESP dashboard
```

## Spam Filter Scoring

Weighted scoring system (SpamAssassin threshold: 5.0):

| Category | Weight | Examples |
|----------|--------|----------|
| **Authentication** | High | Missing SPF/DKIM/DMARC, failed alignment |
| **Content** | Medium | Trigger words, ALL CAPS, excessive punctuation |
| **Reputation** | High | Sender IP/domain history, blacklist status |
| **Engagement** | High (Gmail) | Open rates, reply rates, spam complaints |
| **Technical** | Medium | Missing headers, malformed HTML, broken links |

### Content Trigger Words

**High-risk** (avoid in subject lines):

| Category | Examples |
|----------|----------|
| Financial | "free money", "earn cash", "no cost", "double your income" |
| Urgency | "act now", "limited time", "expires today", "don't miss out" |
| Claims | "guaranteed", "100% free", "risk-free", "no obligation" |
| Medical | "lose weight", "miracle cure", "anti-aging" |
| Deceptive | "not spam", "this isn't junk", "read immediately" |

**Medium-risk** (use sparingly): "buy now", "order today", "special offer", "discount", "amazing", "urgent", "action required"

**Formatting triggers**: ALL CAPS · excessive `!!!` or `???` · `$$$` · coloured/oversized fonts · hidden text (white on white)

### Content Analysis Checklist

```text
Subject Line:
[ ] Under 50 characters
[ ] No ALL CAPS words
[ ] No excessive punctuation (!!! or ???)
[ ] No high-risk trigger words
[ ] Matches body content (no bait-and-switch)

Body Content:
[ ] Text-to-image ratio above 60:40
[ ] No single large image as entire email
[ ] All images have alt text
[ ] No hidden or invisible text
[ ] Links use reputable domains (no URL shorteners in bulk email)
[ ] Unsubscribe link present and functional
[ ] Physical mailing address included (CAN-SPAM)
[ ] No JavaScript or form elements

HTML Structure:
[ ] Under 102KB total (Gmail clipping threshold)
[ ] No external stylesheets (use inline styles)
[ ] Valid HTML (no unclosed tags)
[ ] No base64-encoded images in body
```

### SpamAssassin Testing

```bash
brew install spamassassin   # macOS
sudo apt-get install spamassassin  # Linux

spamassassin -t < test-email.eml
spamassassin -t -D < test-email.eml 2>&1 | grep -E "^(score|hits|required)"
# Common rules: MISSING_MID, HTML_IMAGE_RATIO_02, RDNS_NONE, URIBL_BLOCKED, BAYES_50
```

### Text-to-Image Ratio

| Ratio | Risk | Guidance |
|-------|------|----------|
| 80%+ text | Low | Ideal |
| 60-80% text | Low | Good balance |
| 40-60% text | Medium | Acceptable with strong auth |
| Under 40% text | High | Likely flagged |
| Image-only | Very High | Almost certainly spam |

Include at least 500 characters of visible text alongside images.

## Inbox Placement Testing

### Seed List Testing

Send from production infrastructure to test accounts on each major provider. Check folder placement:

| Provider | Folders to Check |
|----------|-----------------|
| Gmail (personal) | Inbox, Spam, Promotions, Updates |
| Gmail (Workspace) | Inbox, Spam, Promotions |
| Outlook.com | Inbox, Junk, Other |
| Yahoo Mail | Inbox, Spam |
| iCloud Mail | Inbox, Junk |
| AOL Mail | Inbox, Spam |

### External Placement Services

| Service | Seed Accounts | Pricing |
|---------|--------------|---------|
| GlockApps | 70+ providers | From $59/mo |
| Inbox Placement by Validity | 100+ providers | Enterprise |
| mail-tester.com | Single test | Free (limited) |
| MailGenius | Gmail-focused | Free tier |
| Mailtrap | Sandbox | Free tier |

**mail-tester.com**: Visit, copy unique address, send real email from production, check score (aim 9/10+). Common deductions: missing List-Unsubscribe (−1.0), no DKIM (−0.5), no SPF (−1.0), no DMARC (−1.0), blacklisted (−0.5).

## Provider-Specific Filtering

### Gmail

| Factor | Impact | Notes |
|--------|--------|-------|
| Engagement history | Very High | Open/click rates from your domain |
| Authentication | High | SPF, DKIM, DMARC alignment required |
| List-Unsubscribe | High | Required for bulk senders (>5000/day) since Feb 2024 |
| One-click unsubscribe | High | RFC 8058 List-Unsubscribe-Post header required |
| Spam complaint rate | Very High | Must stay under 0.1% (Google Postmaster Tools) |

**Tabs**: Primary (personal/conversational) · Promotions (marketing — expected for bulk) · Updates (transactional) · Social (social platform notifications). Monitor: postmaster.google.com

### Outlook / Microsoft 365

| Factor | Impact | Notes |
|--------|--------|-------|
| Sender reputation | Very High | IP and domain via SNDS |
| Authentication | High | SPF, DKIM required; DMARC recommended |
| Junk Email Reporting | High | User reports directly affect reputation |

Monitor: sendersupport.olc.protection.outlook.com/snds

### Yahoo / AOL

Requirements since Feb 2024: SPF or DKIM for all senders · DMARC for bulk (>5000/day) · one-click unsubscribe · complaint rate under 0.3%.

## Reputation Management

| Factor | Check With | Target |
|--------|-----------|--------|
| IP reputation | Google Postmaster, SNDS, SenderScore | High/Good |
| Domain reputation | Google Postmaster, Talos Intelligence | High/Good |
| Bounce rate | ESP dashboard | Under 2% |
| Complaint rate | Feedback loops, Postmaster Tools | Under 0.1% |
| Spam trap hits | SNDS, blacklist monitors | Zero |
| Blacklist status | `email-test-suite-helper.sh check-placement` | Not listed |

### IP Warming Schedule

| Day | Daily Volume | Notes |
|-----|-------------|-------|
| 1-3 | 50-100 | Most engaged subscribers only |
| 4-7 | 200-500 | Recent openers |
| 8-14 | 500-2,000 | Active in last 30 days |
| 15-21 | 2,000-10,000 | Active in last 90 days |
| 22-30 | 10,000-50,000 | Full list (excluding cold) |
| 30+ | Full volume | Monitor metrics closely |

Pause if bounce rate exceeds 5% or complaints exceed 0.1%. Never send to purchased/scraped lists during warming.

### Feedback Loop (FBL) Registration

Register for complaint notifications and auto-unsubscribe complainers:

| Provider | FBL Registration |
|----------|-----------------|
| Microsoft | sendersupport.olc.protection.outlook.com/snds |
| Yahoo/AOL | help.yahoo.com/kb/postmaster |
| Comcast | postmaster.comcast.net |
| Cloudmark | csi.cloudmark.com/en/feedback |

## Troubleshooting

### Email Landing in Spam

| Cause | Fix |
|-------|-----|
| Missing SPF/DKIM/DMARC | Configure DNS records (see `email-health-check.md`) |
| High complaint rate | Improve opt-in process, honour unsubscribes immediately |
| Blacklisted IP | Request delisting, investigate root cause |
| Spam trigger content | Revise subject line and body copy |
| Low engagement | Clean list, segment by engagement, remove cold subscribers |
| New IP/domain | Follow IP warming schedule |
| Broken unsubscribe | Fix mechanism, add one-click unsubscribe header |

### Email Landing in Promotions (Gmail)

Promotions tab is not spam — emails are delivered. For Primary tab: use plain text, personal tone, avoid marketing language, encourage replies. For bulk marketing, Promotions placement is normal.

### Intermittent Delivery Failures

Check: shared IP reputation · volume spikes · content variations triggering filters · DKIM key rotation alignment · new blacklist additions.

## Related

- `services/email/email-health-check.md` — DNS authentication (SPF, DKIM, DMARC)
- `services/email/email-testing.md` — Design rendering and delivery infrastructure
- `services/email/ses.md` — Amazon SES integration and reputation management
- `content/distribution-email.md` — Email content strategy and sequences
- `scripts/commands/email-test-suite.md`, `scripts/commands/email-health-check.md`

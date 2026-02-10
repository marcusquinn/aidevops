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

# Email Delivery Testing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Test emails against spam filters, verify inbox placement, and analyse content deliverability
- **Scripts**: `email-test-suite-helper.sh check-placement [domain]`, `email-health-check-helper.sh check [domain]`
- **Focus**: Content-level spam triggers, provider-specific filtering, seed list testing, reputation signals
- **Complements**: `email-health-check.md` (DNS auth), `email-testing.md` (design rendering + infrastructure)

**Quick commands:**

```bash
# Inbox placement score
email-test-suite-helper.sh check-placement example.com

# DNS authentication health
email-health-check-helper.sh check example.com

# SMTP delivery test
email-test-suite-helper.sh test-smtp-domain example.com

# Header analysis (check spam verdicts)
email-test-suite-helper.sh analyze-headers headers.txt
```

<!-- AI-CONTEXT-END -->

## Overview

Email delivery testing validates that messages reach the inbox rather than spam or promotions folders. This guide covers three layers:

1. **Content analysis** - Spam trigger detection in subject lines, body, and HTML
2. **Inbox placement** - Provider-specific filtering behaviour and seed list testing
3. **Reputation signals** - Sender score, domain age, engagement history

For DNS authentication (SPF, DKIM, DMARC) see `email-health-check.md`.
For design rendering and SMTP infrastructure see `email-testing.md`.

## Spam Filter Testing

### How Spam Filters Score Emails

Modern spam filters use a weighted scoring system. Each factor adds or subtracts points. Emails exceeding a threshold (typically 5.0 in SpamAssassin) are flagged as spam.

| Category | Weight | Examples |
|----------|--------|----------|
| **Authentication** | High | Missing SPF/DKIM/DMARC, failed alignment |
| **Content** | Medium | Trigger words, ALL CAPS, excessive punctuation |
| **Reputation** | High | Sender IP/domain history, blacklist status |
| **Engagement** | High (Gmail) | Open rates, reply rates, spam complaints |
| **Technical** | Medium | Missing headers, malformed HTML, broken links |

### Content Trigger Words

Spam filters flag specific words and phrases, especially in subject lines. Severity depends on context and combination with other signals.

**High-risk triggers** (avoid in subject lines):

| Category | Examples |
|----------|----------|
| **Financial** | "free money", "earn cash", "no cost", "double your income" |
| **Urgency** | "act now", "limited time", "expires today", "don't miss out" |
| **Claims** | "guaranteed", "100% free", "risk-free", "no obligation" |
| **Medical** | "lose weight", "miracle cure", "anti-aging" |
| **Deceptive** | "not spam", "this isn't junk", "read immediately" |

**Medium-risk triggers** (use sparingly):

| Category | Examples |
|----------|----------|
| **Sales** | "buy now", "order today", "special offer", "discount" |
| **Excitement** | "amazing", "incredible", "unbelievable" |
| **Pressure** | "urgent", "important", "action required" |

**Formatting triggers:**

- ALL CAPS in subject or body (e.g., "FREE OFFER")
- Excessive exclamation marks (!!!)
- Excessive question marks (???)
- Dollar signs with numbers ($$$, $1000)
- Coloured or oversized fonts in body
- Hidden text (white text on white background)

### Content Analysis Checklist

Run through this checklist before sending:

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
[ ] No embedded CSS with !important overuse
[ ] No external stylesheets (use inline styles)
[ ] Valid HTML (no unclosed tags)
[ ] No base64-encoded images in body
```

### SpamAssassin Rule Testing

Test emails locally against SpamAssassin rules:

```bash
# Install SpamAssassin
brew install spamassassin  # macOS
sudo apt-get install spamassassin  # Linux

# Test an email file (.eml format)
spamassassin -t < test-email.eml

# Get detailed score breakdown
spamassassin -t -D < test-email.eml 2>&1 | grep -E "^(score|hits|required)"

# Common rules that trigger:
# MISSING_MID          - No Message-ID header
# HTML_IMAGE_RATIO_02  - Low text-to-image ratio
# RDNS_NONE            - No reverse DNS for sending IP
# URIBL_BLOCKED        - URL on blocklist
# BAYES_50             - Bayesian classifier uncertain
```

### Text-to-Image Ratio

Spam filters penalise emails that are mostly images with little text. This is because spammers use images to bypass text-based content filters.

| Ratio | Risk Level | Guidance |
|-------|-----------|----------|
| **80%+ text** | Low | Ideal for newsletters and transactional |
| **60-80% text** | Low | Good balance for marketing emails |
| **40-60% text** | Medium | Acceptable with strong authentication |
| **Under 40% text** | High | Likely to trigger spam filters |
| **Image-only** | Very High | Almost certainly flagged as spam |

**Best practices:**

- Always include meaningful text alongside images
- Use alt text on all images (displayed when images are blocked)
- Avoid a single hero image as the entire email body
- Include at least 500 characters of visible text

## Inbox Placement Testing

### Seed List Testing

Seed list testing sends emails to accounts across multiple providers to verify inbox placement.

**Manual seed list setup:**

1. Create test accounts on each major provider
2. Send test emails from your production sending infrastructure
3. Check which folder the email lands in (inbox, spam, promotions, updates)
4. Record results and iterate on content/configuration

**Recommended test accounts:**

| Provider | Create At | Folders to Check |
|----------|-----------|-----------------|
| **Gmail** (personal) | gmail.com | Inbox, Spam, Promotions, Updates |
| **Gmail** (Workspace) | Google Workspace | Inbox, Spam, Promotions |
| **Outlook.com** | outlook.com | Inbox, Junk, Other |
| **Yahoo Mail** | yahoo.com | Inbox, Spam |
| **iCloud Mail** | icloud.com | Inbox, Junk |
| **AOL Mail** | aol.com | Inbox, Spam |

**Testing workflow:**

```bash
# 1. Verify DNS authentication first
email-health-check-helper.sh check example.com

# 2. Check infrastructure placement score
email-test-suite-helper.sh check-placement example.com

# 3. Send test email to seed accounts
# (use your actual sending infrastructure, not a different SMTP)

# 4. Check each seed account for placement
# Record: provider, folder, spam score (if visible in headers)

# 5. If landing in spam, analyse headers from the spam copy
email-test-suite-helper.sh analyze-headers spam-copy-headers.txt
```

### External Placement Testing Services

For automated seed list testing across many providers:

| Service | Seed Accounts | Features | Pricing |
|---------|--------------|----------|---------|
| **GlockApps** | 70+ providers | Placement, DMARC, blacklist | From $59/mo |
| **Inbox Placement by Validity** | 100+ providers | Enterprise placement monitoring | Enterprise |
| **mail-tester.com** | Single test | Free deliverability score (1-10) | Free (limited) |
| **MailGenius** | Gmail-focused | Free spam score analysis | Free tier |
| **Mailtrap** | Sandbox | Dev/staging email testing | Free tier |
| **Postmark DMARC** | N/A | Free weekly DMARC digest | Free |

**mail-tester.com workflow:**

```bash
# 1. Visit mail-tester.com and copy the unique test address
# 2. Send a real email from your production system to that address
# 3. Return to mail-tester.com and check your score

# Aim for 9/10 or higher
# Common deductions:
# -1.0  Missing List-Unsubscribe header
# -0.5  No DKIM signature
# -1.0  SPF not configured
# -1.0  DMARC not configured
# -0.5  Listed on a blacklist
# -0.3  SpamAssassin score too high
```

## Provider-Specific Filtering

### Gmail

Gmail uses a machine-learning-based filter that weighs engagement heavily.

**Key factors:**

| Factor | Impact | Notes |
|--------|--------|-------|
| **Engagement history** | Very High | Open/click rates from your domain to Gmail users |
| **Authentication** | High | SPF, DKIM, DMARC alignment required |
| **List-Unsubscribe** | High | Required for bulk senders (>5000/day) since Feb 2024 |
| **One-click unsubscribe** | High | RFC 8058 List-Unsubscribe-Post header required |
| **Spam complaint rate** | Very High | Must stay under 0.1% (Google Postmaster Tools) |
| **Content quality** | Medium | ML-based, learns from user behaviour |

**Gmail tab placement:**

| Tab | Criteria | How to Avoid |
|-----|----------|-------------|
| **Primary** | Personal, conversational emails | Plain text, personal tone, replies |
| **Promotions** | Marketing, offers, newsletters | Difficult to avoid for bulk email |
| **Updates** | Transactional, receipts, notifications | Triggered by transactional content |
| **Social** | Social network notifications | Triggered by social platform headers |

**Gmail monitoring:**

```bash
# Google Postmaster Tools (free)
# - Domain reputation (Bad/Low/Medium/High)
# - Spam rate (must be under 0.1%)
# - Authentication success rates
# - Delivery errors
# Register at: postmaster.google.com
```

### Outlook / Microsoft 365

Microsoft uses SmartScreen and Sender Reputation Data (SRD).

**Key factors:**

| Factor | Impact | Notes |
|--------|--------|-------|
| **Sender reputation** | Very High | IP and domain reputation via SNDS |
| **Authentication** | High | SPF, DKIM required; DMARC recommended |
| **Junk Email Reporting** | High | User reports directly affect reputation |
| **Content filtering** | Medium | SmartScreen ML-based analysis |
| **Safe sender lists** | Medium | Users can whitelist senders |

**Outlook-specific issues:**

- Outlook desktop (Word rendering engine) may display emails differently
- Focused Inbox separates "important" from "other" emails
- EOP (Exchange Online Protection) applies additional enterprise filtering

**Microsoft monitoring:**

```bash
# Microsoft SNDS (Smart Network Data Services)
# - IP reputation and complaint data
# - Trap hit data
# - Sample messages flagged as spam
# Register at: sendersupport.olc.protection.outlook.com/snds
```

### Yahoo / AOL

Yahoo uses a proprietary filter with emphasis on authentication and complaints.

**Key factors:**

| Factor | Impact | Notes |
|--------|--------|-------|
| **Authentication** | Very High | DMARC p=reject enforced for yahoo.com senders |
| **CFL (Complaint Feedback Loop)** | High | Must process complaints promptly |
| **Sender reputation** | High | Based on complaint rates and volume |
| **Content** | Medium | Traditional content filtering |

**Yahoo requirements (since Feb 2024):**

- SPF or DKIM authentication required for all senders
- DMARC required for bulk senders (>5000/day)
- One-click unsubscribe required for bulk senders
- Spam complaint rate must stay under 0.3%

## Reputation Management

### Sender Reputation Factors

| Factor | How to Check | Target |
|--------|-------------|--------|
| **IP reputation** | Google Postmaster, SNDS, SenderScore | High/Good |
| **Domain reputation** | Google Postmaster, Talos Intelligence | High/Good |
| **Bounce rate** | ESP dashboard | Under 2% |
| **Complaint rate** | Feedback loops, Postmaster Tools | Under 0.1% |
| **Spam trap hits** | SNDS, blacklist monitors | Zero |
| **Blacklist status** | `email-test-suite-helper.sh check-placement` | Not listed |
| **Domain age** | WHOIS lookup | Older is better |
| **Sending volume consistency** | ESP dashboard | Gradual ramp, no spikes |

### IP Warming Schedule

New IPs or domains must be warmed gradually to build reputation.

| Day | Daily Volume | Notes |
|-----|-------------|-------|
| 1-3 | 50-100 | Send to most engaged subscribers only |
| 4-7 | 200-500 | Expand to recent openers |
| 8-14 | 500-2,000 | Include subscribers active in last 30 days |
| 15-21 | 2,000-10,000 | Include subscribers active in last 90 days |
| 22-30 | 10,000-50,000 | Full list (excluding cold subscribers) |
| 30+ | Full volume | Monitor metrics closely |

**Warming rules:**

- Send to most engaged subscribers first (recent openers/clickers)
- Monitor bounce and complaint rates at each stage
- Pause and investigate if bounce rate exceeds 5% or complaints exceed 0.1%
- Never send to purchased or scraped lists during warming
- Maintain consistent daily volume (avoid large spikes)

### Feedback Loop (FBL) Setup

Register for complaint feedback loops to receive notifications when recipients mark your email as spam.

| Provider | FBL Registration |
|----------|-----------------|
| **Microsoft** | sendersupport.olc.protection.outlook.com/snds |
| **Yahoo** | help.yahoo.com/kb/postmaster |
| **AOL** | help.yahoo.com/kb/postmaster (merged with Yahoo) |
| **Comcast** | postmaster.comcast.net |
| **Cloudmark** | csi.cloudmark.com/en/feedback |

**FBL processing:**

- Automatically unsubscribe complainers (never email them again)
- Track complaint sources (which campaigns generate complaints)
- Investigate spikes in complaints (content or list quality issue)

## Testing Workflow

### Pre-Send Checklist

```text
Authentication:
[ ] SPF record valid and includes sending IP/service
[ ] DKIM signing enabled and key published
[ ] DMARC policy set (at minimum p=none with rua= reporting)
[ ] List-Unsubscribe header configured
[ ] List-Unsubscribe-Post header configured (one-click)

Content:
[ ] Subject line passes trigger word check
[ ] Text-to-image ratio above 60:40
[ ] All links resolve and use reputable domains
[ ] Unsubscribe link functional
[ ] Physical address included
[ ] No JavaScript or form elements

Infrastructure:
[ ] Sending IP not blacklisted
[ ] Reverse DNS (PTR) configured for sending IP
[ ] TLS enabled on sending server
[ ] Bounce handling configured
[ ] FBL processing active

Reputation:
[ ] Complaint rate under 0.1%
[ ] Bounce rate under 2%
[ ] No recent blacklist additions
[ ] Sending volume consistent with history
```

### Full Testing Sequence

```bash
# Step 1: DNS and authentication
email-health-check-helper.sh check example.com

# Step 2: Infrastructure and placement score
email-test-suite-helper.sh check-placement example.com

# Step 3: SMTP connectivity
email-test-suite-helper.sh test-smtp-domain example.com

# Step 4: Design rendering (if HTML email)
email-test-suite-helper.sh test-design newsletter.html

# Step 5: Send to mail-tester.com for deliverability score
# (manual: send real email, check score)

# Step 6: Send to seed accounts across providers
# (manual: check inbox vs spam placement)

# Step 7: Analyse headers from any spam-folder copies
email-test-suite-helper.sh analyze-headers spam-headers.txt

# Step 8: Monitor post-send
# - Google Postmaster Tools (Gmail reputation)
# - Microsoft SNDS (Outlook reputation)
# - ESP dashboard (bounces, complaints, opens)
```

## Troubleshooting

### Email Landing in Spam

**Diagnosis steps:**

1. Check authentication: `email-health-check-helper.sh check example.com`
2. Check blacklists: `email-test-suite-helper.sh check-placement example.com`
3. Analyse spam copy headers: `email-test-suite-helper.sh analyze-headers headers.txt`
4. Review content for trigger words (see checklist above)
5. Check sender reputation via Google Postmaster / SNDS

**Common causes and fixes:**

| Cause | Fix |
|-------|-----|
| Missing SPF/DKIM/DMARC | Configure DNS records (see `email-health-check.md`) |
| High complaint rate | Improve opt-in process, honour unsubscribes immediately |
| Blacklisted IP | Request delisting, investigate root cause |
| Spam trigger content | Revise subject line and body copy |
| Low engagement | Clean list, segment by engagement, re-engage or remove cold subscribers |
| New IP/domain | Follow IP warming schedule |
| Broken unsubscribe | Fix unsubscribe mechanism, add one-click unsubscribe header |

### Email Landing in Promotions (Gmail)

Gmail's Promotions tab is not spam — emails are still delivered. However, if Primary tab placement is desired:

- Use plain text or minimal HTML formatting
- Write in a personal, conversational tone
- Avoid marketing language and multiple CTAs
- Encourage replies (engagement signals)
- Avoid batch-and-blast patterns (segment and personalise)

Note: For bulk marketing email, Promotions tab placement is normal and expected. Focus on subject line quality to drive opens from the Promotions tab.

### Intermittent Delivery Failures

If emails sometimes reach inbox and sometimes spam:

1. Check for shared IP reputation issues (common with shared ESP IPs)
2. Review sending patterns for volume spikes
3. Check if specific content variations trigger filters
4. Verify DKIM key rotation hasn't caused alignment issues
5. Monitor for new blacklist additions

## Related

- `services/email/email-health-check.md` - DNS authentication checks (SPF, DKIM, DMARC)
- `services/email/email-testing.md` - Design rendering and delivery infrastructure testing
- `services/email/ses.md` - Amazon SES integration and reputation management
- `content/distribution/email.md` - Email content strategy and sequences
- `scripts/commands/email-test-suite.md` - Email test suite slash command
- `scripts/commands/email-health-check.md` - Email health check slash command

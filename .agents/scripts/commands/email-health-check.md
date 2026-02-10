---
description: Check email deliverability health and content quality (SPF, DKIM, DMARC, MX, blacklists, content precheck)
agent: Build+
mode: subagent
---

Check email authentication, deliverability, and content quality.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Check Type

Parse `$ARGUMENTS` to determine which check to run:

- **Domain only** (e.g., `example.com`): Run infrastructure health check
- **HTML file only** (e.g., `newsletter.html`): Run content precheck
- **Domain + file** (e.g., `example.com newsletter.html`): Run full precheck (both)
- **Specific check** (e.g., `example.com spf` or `newsletter.html check-links`): Run individual check

### Step 2: Run Appropriate Check

```bash
# Infrastructure check (domain)
~/.aidevops/agents/scripts/email-health-check-helper.sh check "$DOMAIN"

# Content precheck (HTML file)
~/.aidevops/agents/scripts/email-health-check-helper.sh content-check "$FILE"

# Full precheck (domain + HTML file)
~/.aidevops/agents/scripts/email-health-check-helper.sh precheck "$DOMAIN" "$FILE"
```

### Step 3: Present Results

Format the output as a clear report:

```text
Email Health Check: {domain}

Infrastructure (15 pts):
  SPF:       {status} - {details}
  DKIM:      {status} - {selectors found}
  DMARC:     {status} - {policy}
  MX:        {status} - {record count}
  Blacklist: {status} - {listed/clean}

Content (10 pts):
  Subject:       {status} - {length, issues}
  Preheader:     {status} - {length, issues}
  Accessibility: {status} - {issues found}
  Links:         {status} - {count, issues}
  Images:        {status} - {count, issues}
  Spam Words:    {status} - {count found}

Combined Score: {score}/25 ({pct}%) - Grade: {grade}

Issues Found:
- {issue 1}
- {issue 2}

Recommendations:
1. {recommendation 1}
2. {recommendation 2}
```

### Step 4: Offer Follow-up Actions

```text
Actions:
1. Check specific DKIM selector
2. View detailed blacklist report
3. Run content precheck on HTML file
4. Get mail-tester.com instructions
5. Show DNS records to add/fix
```

## Options

| Command | Purpose |
|---------|---------|
| `/email-health-check example.com` | Full infrastructure check |
| `/email-health-check newsletter.html` | Full content precheck |
| `/email-health-check example.com newsletter.html` | Combined precheck |
| `/email-health-check example.com spf` | SPF only |
| `/email-health-check example.com dkim google` | DKIM with selector |
| `/email-health-check newsletter.html check-links` | Link validation only |
| `/email-health-check newsletter.html check-subject` | Subject line check only |

## Examples

**Infrastructure check:**

```text
User: /email-health-check example.com
AI: Running email health check for example.com...

    Email Health Check: example.com
    
    SPF:       OK - v=spf1 include:_spf.google.com ~all
    DKIM:      OK - Found: google, selector1
    DMARC:     WARN - p=none (monitoring only)
    MX:        OK - 2 records (redundant)
    Blacklist: OK - Not listed
    
    Score: 12/15 (80%) - Grade: B
    
    Recommendations:
    1. Upgrade DMARC policy from p=none to p=quarantine
    2. Consider adding rua= for DMARC reports
```

**Content precheck:**

```text
User: /email-health-check newsletter.html
AI: Running content precheck for newsletter.html...

    Content Precheck: newsletter.html
    
    Subject:       OK - "5 AI tools that save 10 hours/week" (42 chars)
    Preheader:     OK - 85 chars, good length
    Accessibility: WARN - 2 images missing alt text
    Links:         OK - 12 links, unsubscribe present
    Images:        WARN - 1 image missing dimensions
    Spam Words:    OK - No triggers found
    
    Score: 8/10 (80%) - Grade: B
    
    Recommendations:
    1. Add alt text to all images
    2. Add width/height to images to prevent layout shift
```

**Combined precheck:**

```text
User: /email-health-check example.com newsletter.html
AI: Running full precheck...

    Infrastructure: 12/15 (80%)
    Content:        8/10 (80%)
    Combined:      20/25 (80%) - Grade: B
```

## Related

- `services/email/email-health-check.md` - Full documentation
- `services/email/email-testing.md` - Design rendering and delivery testing
- `content/distribution/email.md` - Email content strategy
- `services/email/ses.md` - Amazon SES integration

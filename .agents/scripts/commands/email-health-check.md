---
description: Check email deliverability health and content quality (SPF, DKIM, DMARC, MX, blacklists, content precheck)
agent: Build+
mode: subagent
---

Check email authentication, deliverability, and content quality.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Parse Arguments

- **Domain only** (e.g., `example.com`): Infrastructure health check
- **HTML file only** (e.g., `newsletter.html`): Content precheck
- **Domain + file** (e.g., `example.com newsletter.html`): Full precheck (both)
- **Specific check** (e.g., `example.com spf` or `newsletter.html check-links`): Individual check

### Step 2: Run Check

```bash
# Infrastructure check (domain)
~/.aidevops/agents/scripts/email-health-check-helper.sh check "$DOMAIN"

# Content precheck (HTML file)
~/.aidevops/agents/scripts/email-health-check-helper.sh content-check "$FILE"

# Full precheck (domain + HTML file)
~/.aidevops/agents/scripts/email-health-check-helper.sh precheck "$DOMAIN" "$FILE"
```

### Step 3: Present Results

Present the helper output as a formatted report. Scoring: Infrastructure /15 pts (SPF, DKIM, DMARC, MX, Blacklist), Content /10 pts (Subject, Preheader, Accessibility, Links, Images, Spam Words), Combined /25 pts with letter grade. Include issues found and actionable recommendations.

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
| `/email-health-check accessibility newsletter.html` | Email accessibility audit |

## Example

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

## Related

- `services/email/email-health-check.md` - Full documentation
- `services/email/email-testing.md` - Design rendering and delivery testing
- `content/distribution-email.md` - Email content strategy
- `services/email/ses.md` - Amazon SES integration
- `tools/accessibility/accessibility.md` - WCAG accessibility reference

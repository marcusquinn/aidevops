---
description: Check email deliverability health and content quality (SPF, DKIM, DMARC, MX, blacklists, content precheck)
agent: Build+
mode: subagent
---

Check email authentication, deliverability, and content quality.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Detect mode and run the helper

- `example.com` → infrastructure: `email-health-check-helper.sh check "$DOMAIN"`
- `newsletter.html` → content: `email-health-check-helper.sh content-check "$FILE"`
- `example.com newsletter.html` → combined: `email-health-check-helper.sh precheck "$DOMAIN" "$FILE"`
- `example.com spf` / `newsletter.html check-links` → targeted check

```bash
# Domain only
~/.aidevops/agents/scripts/email-health-check-helper.sh check "$DOMAIN"

# HTML file only
~/.aidevops/agents/scripts/email-health-check-helper.sh content-check "$FILE"

# Domain + HTML file
~/.aidevops/agents/scripts/email-health-check-helper.sh precheck "$DOMAIN" "$FILE"
```

### Step 2: Return a formatted report

- Score infrastructure out of 15: SPF, DKIM, DMARC, MX, blacklist
- Score content out of 10: subject, preheader, accessibility, links, images, spam words
- Show combined score out of 25 with letter grade when both checks run
- Preserve helper findings verbatim and end with actionable recommendations

## Options

| Command | Purpose |
|---------|---------|
| `/email-health-check example.com` | Infrastructure check |
| `/email-health-check newsletter.html` | Content precheck |
| `/email-health-check example.com newsletter.html` | Combined precheck |
| `/email-health-check example.com spf` | SPF only |
| `/email-health-check example.com dkim google` | DKIM with selector |
| `/email-health-check newsletter.html check-links` | Link validation only |
| `/email-health-check newsletter.html check-subject` | Subject line check only |
| `/email-health-check accessibility newsletter.html` | Email accessibility audit |

## Example

```text
User: /email-health-check example.com
AI: Email Health Check: example.com
    SPF: OK - v=spf1 include:_spf.google.com ~all
    DKIM: OK - Found: google, selector1
    DMARC: WARN - p=none (monitoring only)
    MX: OK - 2 records (redundant)
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

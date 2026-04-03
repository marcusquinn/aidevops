---
description: Check email deliverability health and content quality (SPF, DKIM, DMARC, MX, blacklists, content precheck)
agent: Build+
mode: subagent
---

## Workflow

Select and run the helper based on arguments:

- `example.com` → infrastructure: `email-health-check-helper.sh check "$DOMAIN"`
- `newsletter.html` → content: `email-health-check-helper.sh content-check "$FILE"`
- `example.com newsletter.html` → combined: `email-health-check-helper.sh precheck "$DOMAIN" "$FILE"`
- Extra selector/check arg (`example.com spf`, `newsletter.html check-links`) → targeted check

Format the report from helper output:

- Infrastructure: score out of 15 for SPF, DKIM, DMARC, MX, blacklist
- Content: score out of 10 for subject, preheader, accessibility, links, images, spam words
- Combined: score out of 25 with a letter grade
- Keep helper findings verbatim; end with actionable recommendations

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

## Example output (`/email-health-check example.com`)

```text
Email Health Check: example.com
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

---
description: Check email deliverability health and content quality (SPF, DKIM, DMARC, MX, blacklists, content precheck)
agent: Build+
mode: subagent
---

Arguments: `$ARGUMENTS`

## Dispatch

Parse `$ARGUMENTS` and call the appropriate helper:

| Argument pattern | Command |
|-----------------|---------|
| `example.com` | `email-health-check-helper.sh check "$DOMAIN"` |
| `newsletter.html` | `email-health-check-helper.sh content-check "$FILE"` |
| `example.com newsletter.html` | `email-health-check-helper.sh precheck "$DOMAIN" "$FILE"` |
| `example.com spf` / `newsletter.html check-links` | targeted check (extra arg passed through) |

## Report Format

- Infrastructure: score out of 15 (SPF, DKIM, DMARC, MX, blacklist)
- Content: score out of 10 (subject, preheader, accessibility, links, images, spam words)
- Combined: score out of 25 with letter grade
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
| `/email-health-check accessibility newsletter.html` | Accessibility audit |

## Related

- `services/email/email-health-check.md` — full documentation
- `services/email/email-testing.md` — design rendering and delivery testing
- `content/distribution-email.md` — email content strategy
- `services/email/ses.md` — Amazon SES integration
- `tools/accessibility/accessibility.md` — WCAG accessibility reference

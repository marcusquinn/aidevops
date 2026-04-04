---
description: Run email design rendering and delivery tests
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run email testing suite for design rendering validation or delivery testing.

Arguments: $ARGUMENTS

## Workflow

Dispatch based on argument type:

| Argument | Command |
|----------|---------|
| HTML file path | `~/.aidevops/agents/scripts/email-test-suite-helper.sh test-design "$ARGUMENTS"` |
| Domain | `~/.aidevops/agents/scripts/email-test-suite-helper.sh check-placement "$ARGUMENTS"` |
| `smtp <host> <port>` | `~/.aidevops/agents/scripts/email-test-suite-helper.sh smtp "$ARGUMENTS"` |
| `headers <file>` | `~/.aidevops/agents/scripts/email-test-suite-helper.sh headers "$ARGUMENTS"` |
| `accessibility <file>` | `~/.aidevops/agents/scripts/email-test-suite-helper.sh test-design "$ARGUMENTS"` |
| `generate` | `~/.aidevops/agents/scripts/email-test-suite-helper.sh generate` |
| `help` or empty | Show Options table below |

Present results grouped by category with severity-highlighted issues and actionable recommendations.

## Options

| Command | Purpose |
|---------|---------|
| `/email-test-suite newsletter.html` | Design rendering tests (includes accessibility) |
| `/email-test-suite example.com` | Inbox placement analysis |
| `/email-test-suite accessibility newsletter.html` | Email accessibility check only |
| `/email-test-suite smtp mail.example.com 587` | SMTP connectivity test |
| `/email-test-suite headers headers.txt` | Header analysis |
| `/email-test-suite generate` | Generate test email template |

## Related

- `services/email/email-testing.md` - Full documentation
- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/ses.md` - Amazon SES integration
- `tools/accessibility/accessibility.md` - WCAG accessibility reference

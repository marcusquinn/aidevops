---
description: Test email design locally and via Email on Acid API for real-client rendering
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Arguments: $ARGUMENTS

## Dispatch

Parse `$ARGUMENTS`: HTML file path → local tests; `eoa` prefix → EOA API commands; empty/help → show usage.

| Mode | Command |
|------|---------|
| Local tests (no API key) | `email-design-test-helper.sh test "$ARGUMENTS"` |
| Full EOA test (local + API rendering) | `email-design-test-helper.sh eoa-test "$ARGUMENTS"` |
| Sandbox mode (no API key) | `email-design-test-helper.sh eoa-sandbox "$ARGUMENTS"` |

All scripts at `~/.aidevops/agents/scripts/`.

## Output

Present results as a report: local test results (HTML, CSS, dark mode, responsive, accessibility, images, links), EOA screenshots grouped by client category, issues with severity, actionable recommendations.

Follow-up actions: full health check (`email-health-check-helper.sh`), view client screenshot, reprocess failures, get inlined CSS, run delivery/placement tests.

## Commands

| Command | Purpose |
|---------|---------|
| `/email-design-test newsletter.html` | Local design tests only |
| `/email-design-test eoa-sandbox newsletter.html` | Sandbox test (no API key) |
| `/email-design-test eoa-test newsletter.html "Subject" outlook16,gmail_chr26_win` | Full EOA test with specific clients |
| `/email-design-test eoa-results abc123` | Get results for existing test |
| `/email-design-test eoa-clients` | List available email clients |

## Related

- `services/email/email-design-test.md` - Full documentation
- `services/email/email-testing.md` - Design rendering + delivery testing
- `services/email/email-health-check.md` - DNS authentication checks

---
description: Test email design locally and via Email on Acid (EOA) API
agent: Build+
mode: subagent
---

Run local email design tests (HTML, CSS, accessibility, images, links) and optionally submit to EOA for real-client rendering.

Arguments: $ARGUMENTS

## Dispatch

Parse `$ARGUMENTS`: HTML path → local tests; `eoa` prefix → EOA API; empty/help → usage.

- **Local (no API key):** `~/.aidevops/agents/scripts/email-design-test-helper.sh test "$ARGUMENTS"`
- **Full EOA (API):** `~/.aidevops/agents/scripts/email-design-test-helper.sh eoa-test "$ARGUMENTS"`
- **Sandbox (no API key):** `~/.aidevops/agents/scripts/email-design-test-helper.sh eoa-sandbox "$ARGUMENTS"`

## Output

Report: local results (HTML/CSS/dark/responsive/a11y/images/links), EOA screenshots (grouped by client), issues by severity, recommendations.

Follow-up: `email-health-check-helper.sh`, view screenshot, reprocess failures, get inlined CSS, delivery/placement tests.

## Commands

| Command | Purpose |
|---------|---------|
| `/email-design-test file.html` | Local design tests only |
| `/email-design-test eoa-sandbox file.html` | Sandbox test (no API key) |
| `/email-design-test eoa-test file.html "Subj" c1,c2` | Full EOA test (specific clients) |
| `/email-design-test eoa-results ID` | Get results for existing test |
| `/email-design-test eoa-clients` | List available email clients |

## Related

- `services/email/email-design-test.md` (Full docs)
- `services/email/email-testing.md` (Rendering + delivery)
- `services/email/email-health-check.md` (DNS/Auth)

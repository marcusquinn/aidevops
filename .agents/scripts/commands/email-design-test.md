---
description: Test email design locally and via Email on Acid API for real-client rendering
agent: Build+
mode: subagent
---

Run email design tests locally (HTML validation, CSS compatibility, accessibility, images, links) and optionally submit to Email on Acid for real-client rendering screenshots.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Test Mode

Parse `$ARGUMENTS` to determine what to run:

- If argument is an HTML file path: run local design tests
- If argument starts with "eoa": run Email on Acid API commands
- If argument is "help" or empty: show available commands

### Step 2: Run Appropriate Tests

**Local design tests (no API key needed):**

```bash
~/.aidevops/agents/scripts/email-design-test-helper.sh test "$ARGUMENTS"
```

**Full EOA test (local + API rendering):**

```bash
~/.aidevops/agents/scripts/email-design-test-helper.sh eoa-test "$ARGUMENTS"
```

**Sandbox mode (no API key needed):**

```bash
~/.aidevops/agents/scripts/email-design-test-helper.sh eoa-sandbox "$ARGUMENTS"
```

### Step 3: Present Results

Format the output as a clear report with:

- Local test results (HTML, CSS, dark mode, responsive, accessibility, images, links)
- EOA rendering screenshots grouped by client category (Application, Mobile, Web)
- Issues highlighted with severity
- Actionable recommendations

### Step 4: Offer Follow-up Actions

```text
Actions:
1. Run full health check (email-health-check-helper.sh)
2. View specific client screenshot
3. Reprocess failed screenshots
4. Get inlined CSS version
5. Run delivery/placement tests
```

## Options

| Command | Purpose |
|---------|---------|
| `/email-design-test newsletter.html` | Local design tests only |
| `/email-design-test eoa-sandbox newsletter.html` | Sandbox test (no API key) |
| `/email-design-test eoa-test newsletter.html "Subject" outlook16,gmail_chr26_win` | Full EOA test with specific clients |
| `/email-design-test eoa-results abc123` | Get results for existing test |
| `/email-design-test eoa-clients` | List available email clients |

## Examples

**Local design test:**

```text
User: /email-design-test newsletter.html
AI: Running local design tests on newsletter.html...

    HTML Structure: OK (2 warnings)
    CSS Compatibility: 1 issue (flexbox in Outlook)
    Dark Mode: OK
    Responsive: OK
    Accessibility: 1 warning (missing role="presentation")
    Images: OK (3 images, all with dimensions)
    Links: OK (12 links, all HTTPS)
    Preheader: Detected

    For real-client rendering: eoa-test newsletter.html
```

**EOA sandbox test:**

```text
User: /email-design-test eoa-sandbox newsletter.html
AI: Running sandbox test (no actual screenshots)...

    Local Tests: Passed (2 warnings)
    EOA Test Created: sandbox-abc123
    Status: Sandbox mode - no actual rendering

    To run real tests, configure EOA API credentials:
    aidevops secret set EOA_API_KEY
    aidevops secret set EOA_API_PASSWORD
```

## Related

- `services/email/email-design-testing.md` - Full documentation
- `services/email/email-testing.md` - Design rendering + delivery testing
- `services/email/email-health-check.md` - DNS authentication checks

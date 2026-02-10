---
description: Run email design rendering and delivery tests
agent: Build+
mode: subagent
---

Run email testing suite for design rendering validation or delivery testing.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Test Type

Parse `$ARGUMENTS` to determine what to test:

- If argument is an HTML file path: run design rendering tests
- If argument is a domain: run delivery/placement tests
- If argument is "generate": generate a test email template
- If argument is "help" or empty: show available commands

### Step 2: Run Appropriate Tests

**For HTML files (design rendering):**

```bash
~/.aidevops/agents/scripts/email-test-suite-helper.sh test-design "$ARGUMENTS"
```

**For domains (delivery testing):**

```bash
~/.aidevops/agents/scripts/email-test-suite-helper.sh check-placement "$ARGUMENTS"
```

**For SMTP testing:**

```bash
~/.aidevops/agents/scripts/email-test-suite-helper.sh test-smtp-domain "$ARGUMENTS"
```

### Step 3: Present Results

Format the output as a clear report with:

- Test results grouped by category
- Issues highlighted with severity
- Actionable recommendations
- Links to external testing services

### Step 4: Offer Follow-up Actions

```text
Actions:
1. Run full health check (email-health-check-helper.sh)
2. Test specific email client compatibility
3. Analyze email headers
4. Generate test email template
5. Test SMTP connectivity
```

## Options

| Command | Purpose |
|---------|---------|
| `/email-test-suite newsletter.html` | Design rendering tests |
| `/email-test-suite example.com` | Inbox placement analysis |
| `/email-test-suite smtp mail.example.com 587` | SMTP connectivity test |
| `/email-test-suite headers headers.txt` | Header analysis |
| `/email-test-suite generate` | Generate test email template |

## Examples

**Design rendering test:**

```text
User: /email-test-suite newsletter.html
AI: Running design rendering tests on newsletter.html...

    HTML Structure: 1 issue, 2 warnings
    CSS Compatibility: 3 issues (flexbox, grid, animation)
    Dark Mode: 2 warnings (hardcoded colors)
    Responsive: OK

    Top Issues:
    1. Flexbox layout will break in Outlook
    2. Missing color-scheme meta for dark mode
    3. CSS animations not supported in most clients

    Recommendations:
    1. Replace flexbox with table-based layout
    2. Add dark mode meta tags and media queries
    3. Remove CSS animations or use as progressive enhancement
```

**Inbox placement check:**

```text
User: /email-test-suite example.com
AI: Checking inbox placement factors for example.com...

    Score: 8/10 - Good

    SPF:       PASS (enforcing)
    DKIM:      PASS (google selector)
    DMARC:     PASS (p=quarantine)
    MX:        OK (2 records)
    PTR:       OK (matches MX)
    MTA-STS:   Not configured
    TLS-RPT:   Not configured
    BIMI:      Not configured
    Blacklist: Clean

    Recommendations:
    1. Add MTA-STS for TLS enforcement
    2. Add TLS-RPT for failure reporting
```

## Related

- `services/email/email-testing.md` - Full documentation
- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/ses.md` - Amazon SES integration

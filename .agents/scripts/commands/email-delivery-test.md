---
description: Run spam content analysis and inbox placement tests
agent: Build+
mode: subagent
---

Run email deliverability testing — spam content analysis, provider-specific checks, and inbox placement guidance.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Determine Test Type

Parse `$ARGUMENTS` to determine what to test:

- If argument is an HTML/text file path: run spam content analysis
- If argument is a domain: run provider deliverability checks
- If argument is "warmup": show warm-up guidance
- If argument is "seed-test": show seed-list testing guide
- If argument is "help" or empty: show available commands

### Step 2: Run Appropriate Tests

**For email content (spam analysis):**

```bash
~/.aidevops/agents/scripts/email-delivery-test-helper.sh spam-check "$ARGUMENTS"
```

**For domains (provider deliverability):**

```bash
~/.aidevops/agents/scripts/email-delivery-test-helper.sh providers "$ARGUMENTS"
```

**For full report:**

```bash
~/.aidevops/agents/scripts/email-delivery-test-helper.sh report "$ARGUMENTS"
```

### Step 3: Present Results

Format the output as a clear report with:

- Spam score and risk rating
- Provider-specific scores (Gmail, Outlook, Yahoo)
- Actionable recommendations
- Links to monitoring services

### Step 4: Offer Follow-up Actions

```text
Actions:
1. Run full deliverability report
2. Check specific provider (Gmail/Outlook/Yahoo)
3. Analyse email content for spam triggers
4. View warm-up schedule
5. Run seed-list placement test
```

## Options

| Command | Purpose |
|---------|---------|
| `/email-delivery-test newsletter.html` | Spam content analysis |
| `/email-delivery-test example.com` | All-provider deliverability check |
| `/email-delivery-test gmail example.com` | Gmail-specific check |
| `/email-delivery-test warmup example.com` | Warm-up guidance |
| `/email-delivery-test seed-test example.com` | Seed-list testing guide |

## Examples

**Spam content analysis:**

```text
User: /email-delivery-test newsletter.html
AI: Running spam content analysis on newsletter.html...

    Subject Line: 2 issues (excessive caps, exclamation marks)
    Body Content: 3 high-risk phrases, 5 medium-risk phrases
    Structural: Low text-to-image ratio, missing physical address

    Spam Score: 45/100 - MEDIUM RISK
    Content may trigger spam filters in some providers

    Top Issues:
    1. "Act now" and "Limited time" are high-risk phrases
    2. Image-heavy with little text content
    3. Missing physical address (CAN-SPAM requirement)
```

**Provider deliverability check:**

```text
User: /email-delivery-test example.com
AI: Checking deliverability across major providers...

    Gmail:   7/8 - Excellent
    Outlook: 5/7 - Good
    Yahoo:   4/5 - Good

    All providers require:
    - SPF + DKIM + DMARC enforcement
    - One-click unsubscribe headers
    - Spam rate < 0.3%
```

## Related

- `services/email/email-delivery-testing.md` - Full documentation
- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/email-testing.md` - Design rendering tests

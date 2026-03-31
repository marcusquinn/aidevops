---
description: Run spam content analysis and inbox placement tests
agent: Build+
mode: subagent
---

Run email deliverability testing: spam analysis, provider checks, warm-up guidance, and seed-list guidance.

Arguments: `$ARGUMENTS`

## Workflow

### Step 1: Classify Input

- File path → spam content analysis
- Domain → all-provider deliverability check
- `gmail|outlook|yahoo <domain>` → provider-specific check
- `warmup <domain>` → warm-up guidance
- `seed-test <domain>` → inbox placement test guide
- `report <domain>` → full report
- Empty or `help` → helper usage

### Step 2: Run Helper

```bash
# File path
~/.aidevops/agents/scripts/email-delivery-test-helper.sh spam-check "$ARGUMENTS"

# Domain or subcommand
~/.aidevops/agents/scripts/email-delivery-test-helper.sh "$ARGUMENTS"
```

### Step 3: Present Results

Present helper output as a concise report:

- Spam score and risk level
- Provider scores and failures
- Actionable remediation steps
- Relevant monitoring or follow-up links

## Options

| Command | Purpose |
|---------|---------|
| `/email-delivery-test newsletter.html` | Spam content analysis |
| `/email-delivery-test example.com` | All-provider deliverability check |
| `/email-delivery-test gmail example.com` | Gmail-specific check |
| `/email-delivery-test warmup example.com` | Warm-up guidance |
| `/email-delivery-test seed-test example.com` | Seed-list testing guide |

## Related

- `services/email/email-delivery-test.md` - Full documentation
- `services/email/email-health-check.md` - DNS authentication checks
- `services/email/email-testing.md` - Design rendering tests

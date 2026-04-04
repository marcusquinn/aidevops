---
description: Run spam content analysis and inbox placement tests
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run email deliverability testing — spam content analysis, provider-specific checks, and inbox placement guidance.

Arguments: $ARGUMENTS

## Dispatch

Parse `$ARGUMENTS` and call the appropriate helper:

| Argument type | Command |
|---------------|---------|
| HTML/text file path | `email-delivery-test-helper.sh spam-check "$ARGUMENTS"` |
| Domain | `email-delivery-test-helper.sh providers "$ARGUMENTS"` |
| `warmup <domain>` | `email-delivery-test-helper.sh report "$ARGUMENTS"` (warm-up guidance) |
| `seed-test <domain>` | `email-delivery-test-helper.sh report "$ARGUMENTS"` (seed-list guide) |
| `gmail <domain>` | `email-delivery-test-helper.sh providers gmail "$ARGUMENTS"` |
| empty / `help` | Show options table below |

All helpers live at `~/.aidevops/agents/scripts/email-delivery-test-helper.sh`.

## Present Results

Format output as:
- Spam score and risk rating
- Provider-specific scores (Gmail, Outlook, Yahoo)
- Actionable recommendations
- Links to monitoring services

Then offer follow-up: full report · specific provider · spam content analysis · warm-up schedule · seed-list test.

## Related

- `services/email/email-delivery-test.md` — full documentation
- `services/email/email-health-check.md` — DNS authentication checks
- `services/email/email-testing.md` — design rendering tests

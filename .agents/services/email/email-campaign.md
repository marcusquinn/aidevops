---
description: Create and manage newsletter or broadcast email campaigns
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Arguments: $ARGUMENTS

## Workflow

1. **Parse intent:** Extract campaign type (`newsletter`, `broadcast`, `sequence`), action (`create`, `schedule`, `send`, `pause`, `status`, `analytics`), and optional audience segment. Missing type → request it.
2. **Validate:** For create/schedule/send confirm: subject + preview text, audience segment, single primary CTA, send window/timezone, compliance footer + unsubscribe handling.
3. **Execute:**

```bash
~/.aidevops/agents/scripts/email-agent-helper.sh send --mission "$MISSION_ID" --template "$TEMPLATE"
~/.aidevops/agents/scripts/email-health-check-helper.sh precheck "$DOMAIN" "$HTML_FILE"
~/.aidevops/agents/scripts/email-delivery-test-helper.sh report "$DOMAIN"
```

CRM-first operations (segmentation, automations, broadcasts) → route to configured CRM tooling flow.

4. **Report:** campaign type/ID/state, segment size + send count, send window/cadence, key metrics (open, click, reply, unsubscribe, spam complaint), recommended optimization action.
5. **Follow-up:** A/B test subject lines · re-segment non-openers · tune CTA · schedule next in sequence · export performance summary.

## Commands

| Command | Purpose |
|---------|---------|
| `/email-campaign newsletter create "Weekly AI Ops"` | Create newsletter draft |
| `/email-campaign broadcast schedule campaign_101 tomorrow-09:00` | Schedule broadcast send |
| `/email-campaign sequence status seq_77` | Show sequence state and progress |
| `/email-campaign newsletter analytics campaign_101` | Show campaign metrics snapshot |
| `/email-campaign broadcast pause campaign_101` | Pause pending or active campaign |

## Related

- `content/distribution-email.md` — Newsletter and sequence strategy
- `services/email/email-testing.md` — Design and delivery testing workflow
- `services/email/email-delivery-test.md` — Inbox placement and spam scoring
- `services/email/email-health-check.md` — DNS and content precheck

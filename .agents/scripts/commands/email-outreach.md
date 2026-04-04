---
description: Launch and manage cold outreach campaigns (Smartlead, Instantly, ManyReach)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Launch or operate outbound cold email campaigns.

Arguments: `$ARGUMENTS`

## Workflow

1. **Parse platform and action**: `smartlead`, `instantly`, `manyreach`, `help`. Actions: `launch`, `warmup`, `leads`, `pause`, `status`, `analytics`.
2. **Validate launch inputs**: Require objective, offer, mailbox/domain, lead source, volume target, and warmup status.
3. **Enforce outreach-policy**:
    - New mailbox ramp: `5-8/day` to `17-20/day` over 4 weeks.
    - Hard cap: `100/day` per mailbox (including follow-ups).
    - Include unsubscribe and legal footer controls.
4. **Run platform helper**:

    ```bash
    ~/.aidevops/agents/scripts/<platform>-helper.sh create-campaign "$CAMPAIGN_NAME"
    ~/.aidevops/agents/scripts/<platform>-helper.sh import-leads "$LEADS_FILE"
    ~/.aidevops/agents/scripts/<platform>-helper.sh set-limits "$CAMPAIGN_ID" "$DAILY_LIMIT"
    ```

5. **Return campaign state**: Report ID, status, mailboxes, warmup stage, lead count, sequence status, and risk flags (bounce, complaint, reply handling).
6. **Offer follow-up actions**: Add leads, adjust volume/warmup, pause unhealthy mailboxes, view replies, or export analytics.

## Options

| Command | Purpose |
|---------|---------|
| `/email-outreach smartlead launch "UK SaaS Founders"` | Create and launch campaign in Smartlead |
| `/email-outreach instantly leads campaign_123 leads.csv` | Import leads into an Instantly campaign |
| `/email-outreach manyreach warmup campaign_456 20` | Set warmup/daily volume in ManyReach |
| `/email-outreach smartlead pause campaign_123` | Pause campaign immediately |
| `/email-outreach instantly analytics campaign_123` | Show campaign analytics snapshot |

## Examples

**Launch campaign:**

```text
User: /email-outreach smartlead launch "US agency owners"
AI: Launching Smartlead campaign (cmp_98321)... Mailboxes: send1@outreach-domain.com (week 2 warmup, 12/day), send2@outreach-domain.com (week 1 warmup, 8/day). Next: Import leads, compliance check.
```

**Operational status check:**

```text
User: /email-outreach instantly status campaign_123
AI: Campaign campaign_123: Running. Leads: 1,240 (118 today). Replies: 37 (9 pos, 18 neut, 10 obj). Risk: Low (bounce 1.4%). Rec: Keep volume stable for 48h.
```

## Related

- `services/outreach/cold-outreach.md` - Strategy and guardrails
- `services/email/email-health-check.md` - Authentication and infrastructure
- `content/distribution-email.md` - Email copy and performance guidance

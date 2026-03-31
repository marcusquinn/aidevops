---
description: Launch and manage cold outreach campaigns across supported platforms
agent: Build+
mode: subagent
---

Launch or operate outbound cold email campaigns.

Arguments: `$ARGUMENTS`

## Workflow

### 1. Parse platform and action

- Platform: `smartlead`, `instantly`, `manyreach`, `help`
- Action: `launch`, `warmup`, `leads`, `pause`, `status`, `analytics`
- Missing platform: ask for one and show supported options

### 2. Validate launch inputs

Require before launch:

- Campaign objective and offer
- Sending mailbox or domain
- Lead source or lead list path
- Daily volume target and warmup status

Enforce outreach-policy defaults:

- New mailbox ramp: `5-8/day` to `17-20/day` over 4 weeks
- Hard cap: `100/day` per mailbox, including follow-ups
- Include unsubscribe and legal footer controls

### 3. Run the platform helper

```bash
# Create campaign
~/.aidevops/agents/scripts/smartlead-helper.sh create-campaign "$CAMPAIGN_NAME"
~/.aidevops/agents/scripts/instantly-helper.sh create-campaign "$CAMPAIGN_NAME"
~/.aidevops/agents/scripts/manyreach-helper.sh create-campaign "$CAMPAIGN_NAME"

# Import leads
~/.aidevops/agents/scripts/<platform>-helper.sh import-leads "$LEADS_FILE"

# Configure warmup and sending limits
~/.aidevops/agents/scripts/<platform>-helper.sh set-limits "$CAMPAIGN_ID" "$DAILY_LIMIT"
```

### 4. Return campaign state

Report:

- Platform, campaign ID, status
- Attached mailboxes and warmup stage
- Lead count and sequence status
- Risk flags: bounce, complaint, reply handling
- Recommended next action

### 5. Offer follow-up actions

```text
Actions:
1. Add another lead segment
2. Adjust daily volume and warmup settings
3. Pause mailbox with low health
4. View reply classifications
5. Export campaign analytics
```

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
AI: Launching Smartlead campaign...

    Platform: Smartlead
    Campaign: US agency owners (cmp_98321)
    Status: Draft created

    Mailboxes:
    - send1@outreach-domain.com (week 2 warmup, 12/day)
    - send2@outreach-domain.com (week 1 warmup, 8/day)

    Next steps:
    1. Import lead segment
    2. Activate sequence after compliance check
```

**Operational status check:**

```text
User: /email-outreach instantly status campaign_123
AI: Campaign status for campaign_123:

    State: Running
    Leads: 1,240 total, 118 contacted today
    Replies: 37 (positive: 9, neutral: 18, objection: 10)
    Risk: Low (bounce 1.4%, complaints 0.05%)

    Recommendation:
    Keep volume stable for 48h before increasing
```

## Related

- `services/outreach/cold-outreach.md` - Strategy and guardrails
- `services/email/email-health-check.md` - Authentication and infrastructure checks
- `content/distribution-email.md` - Email copy and campaign performance guidance

---
description: Create and manage newsletter or broadcast email campaigns
agent: Build+
mode: subagent
---

Manage newsletter and broadcast campaigns: list setup, send workflow, and analytics review.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Parse Campaign Intent

Parse `$ARGUMENTS` into:

- Campaign type: `newsletter`, `broadcast`, `sequence`, `help`
- Action: `create`, `schedule`, `send`, `pause`, `status`, `analytics`
- Optional audience segment/tag filter

If campaign type is missing, request it and show examples.

### Step 2: Validate Required Inputs

For create/schedule/send actions, confirm:

- Subject line and preview text
- Audience segment/list
- Single primary CTA
- Send window/timezone
- Compliance footer and unsubscribe handling

Before sending, run preflight checks on content and delivery readiness.

### Step 3: Execute Campaign Operation

Use the appropriate helper workflow:

```bash
# Create campaign draft
~/.aidevops/agents/scripts/email-agent-helper.sh send --mission "$MISSION_ID" --template "$TEMPLATE"

# Content and infrastructure preflight
~/.aidevops/agents/scripts/email-health-check-helper.sh precheck "$DOMAIN" "$HTML_FILE"

# Delivery readiness checks
~/.aidevops/agents/scripts/email-delivery-test-helper.sh report "$DOMAIN"
```

If the user asks for CRM-first campaign operations (segmentation, automations, broadcasts), route to the configured CRM tooling flow for contact/list operations.

### Step 4: Return Campaign Report

Include:

- Campaign type, ID, and current state
- Segment/list size and send count
- Send window and cadence
- Key metrics: open, click, reply, unsubscribe, spam complaint
- Recommended optimization action

### Step 5: Offer Follow-up Actions

```text
Actions:
1. A/B test two subject lines
2. Re-segment non-openers for resend
3. Tune CTA placement and copy
4. Schedule next campaign in sequence
5. Export campaign performance summary
```

## Options

| Command | Purpose |
|---------|---------|
| `/email-campaign newsletter create "Weekly AI Ops"` | Create newsletter draft |
| `/email-campaign broadcast schedule campaign_101 tomorrow-09:00` | Schedule broadcast send |
| `/email-campaign sequence status seq_77` | Show sequence state and progress |
| `/email-campaign newsletter analytics campaign_101` | Show campaign metrics snapshot |
| `/email-campaign broadcast pause campaign_101` | Pause pending or active campaign |

## Examples

**Create and schedule newsletter:**

```text
User: /email-campaign newsletter create "Friday Product Brief"
AI: Creating newsletter campaign draft...

    Campaign: Friday Product Brief (camp_101)
    Type: Newsletter
    Segment: Engaged subscribers (8,420 contacts)
    State: Draft

    Next steps:
    1. Run precheck on content and domain
    2. Schedule send window (Tue-Thu 09:00-11:00 local)
```

**Analytics review:**

```text
User: /email-campaign newsletter analytics camp_101
AI: Campaign analytics for camp_101:

    Delivered: 8,297
    Open rate: 37.2%
    Click rate: 4.8%
    Reply rate: 1.3%
    Unsubscribe: 0.21%
    Complaints: 0.03%

    Recommendation:
    Keep audience/offer stable and test two new subject lines next send
```

## Related

- `content/distribution-email.md` - Newsletter and sequence strategy
- `services/email/email-testing.md` - Design and delivery testing workflow
- `services/email/email-delivery-test.md` - Inbox placement and spam scoring
- `services/email/email-health-check.md` - DNS and content precheck

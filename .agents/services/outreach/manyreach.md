---
description: ManyReach cold outreach platform — campaigns, leads, sequences, and mailboxes via API v2
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

# ManyReach

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `scripts/manyreach-helper.sh [command] [subcommand] [options]`
- **API base**: `https://api.manyreach.com/api/v2`
- **Credential**: `MANYREACH_API_KEY` — set via `aidevops secret set MANYREACH_API_KEY`
- **Docs**: https://docs.manyreach.com
- **Strategy context**: `services/outreach/cold-outreach.md`

## Setup

```bash
# Store API key securely
aidevops secret set MANYREACH_API_KEY

# Verify connectivity
scripts/manyreach-helper.sh status
```

## Campaigns

Campaigns are the top-level container for outreach sequences and leads.

```bash
# List all campaigns
scripts/manyreach-helper.sh campaigns list

# Get campaign details
scripts/manyreach-helper.sh campaigns get <campaign_id>

# Create a campaign
scripts/manyreach-helper.sh campaigns create --name "Q2 Outreach" --from-email sender@yourdomain.com

# Pause / resume
scripts/manyreach-helper.sh campaigns pause <campaign_id>
scripts/manyreach-helper.sh campaigns resume <campaign_id>

# Delete
scripts/manyreach-helper.sh campaigns delete <campaign_id>

# Campaign performance stats
scripts/manyreach-helper.sh stats campaign <campaign_id>
```

## Leads

Leads are the contacts enrolled in a campaign.

```bash
# List leads (all, or filtered by campaign)
scripts/manyreach-helper.sh leads list
scripts/manyreach-helper.sh leads list --campaign <campaign_id>
scripts/manyreach-helper.sh leads list --campaign <campaign_id> --page 2

# Get a single lead
scripts/manyreach-helper.sh leads get <lead_id>

# Add a single lead to a campaign
scripts/manyreach-helper.sh leads add \
  --campaign <campaign_id> \
  --email prospect@company.com \
  --first-name Jane \
  --last-name Smith \
  --company "Acme Corp"

# Bulk import from CSV
# CSV must have headers: email, first_name, last_name, company (at minimum)
scripts/manyreach-helper.sh leads import \
  --campaign <campaign_id> \
  --file prospects.csv

# Unsubscribe a lead
scripts/manyreach-helper.sh leads unsubscribe <lead_id>
```

## Sequences

Sequences define the email steps (subject, body, delay) within a campaign.

```bash
# List sequences for a campaign
scripts/manyreach-helper.sh sequences list --campaign <campaign_id>

# Get a sequence step
scripts/manyreach-helper.sh sequences get <sequence_id>

# Add a step to a sequence
scripts/manyreach-helper.sh sequences add-step \
  --sequence <sequence_id> \
  --subject "Following up on my last email" \
  --body "Hi {{first_name}}, just wanted to check in..." \
  --delay-days 3
```

## Mailboxes

Mailboxes are the sending email accounts connected to ManyReach.

```bash
# List all mailboxes
scripts/manyreach-helper.sh mailboxes list

# Get mailbox details (status, warmup, daily limits)
scripts/manyreach-helper.sh mailboxes get <mailbox_id>
```

## JSON Output

All commands accept `--json` to return raw API JSON for scripting:

```bash
scripts/manyreach-helper.sh campaigns list --json | jq '.data[].id'
scripts/manyreach-helper.sh stats campaign <id> --json | jq '{sent, replied}'
```

## Operational Notes

### Sending Limits

ManyReach enforces per-mailbox daily limits. Check current usage before scaling:

```bash
scripts/manyreach-helper.sh mailboxes get <mailbox_id>
# Review: daily_limit and sent_today fields
```

Follow the warmup ramp from `services/outreach/cold-outreach.md`:
- Week 1: 5–8/day per mailbox
- Week 4+: up to 20/day per stable mailbox
- Hard cap: 100/day per mailbox (all outbound activity combined)

### Sequence Personalisation

ManyReach supports `{{variable}}` merge tags in subject and body fields:

| Tag | Source |
|-----|--------|
| `{{first_name}}` | Lead `first_name` field |
| `{{last_name}}` | Lead `last_name` field |
| `{{company}}` | Lead `company` field |
| `{{email}}` | Lead `email` field |

Keep variation high across sequence steps to reduce template fingerprinting.

### Reply Handling

ManyReach auto-stops sequences on any reply. After a reply:
1. Classify: positive, neutral, objection, or unsubscribe
2. Route positive/high-intent replies to a human owner with SLA
3. Feed objection patterns back into copy and segmentation

### Compliance

- Include a physical postal address in every campaign email
- Provide a one-click unsubscribe mechanism
- Honor opt-out requests immediately — use `leads unsubscribe` to suppress
- For EU/UK contacts: document legitimate interest basis before sending

### CSV Import Format

Minimum required columns for bulk import:

```csv
email,first_name,last_name,company
jane@acme.com,Jane,Smith,Acme Corp
bob@example.com,Bob,Jones,Example Ltd
```

Additional custom fields are passed through as merge tags if the campaign template references them.

<!-- AI-CONTEXT-END -->

Use this document for ManyReach-specific execution. For platform selection, warmup strategy, and compliance baseline, read `services/outreach/cold-outreach.md`.

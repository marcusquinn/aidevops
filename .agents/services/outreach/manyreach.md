---
description: ManyReach cold outreach platform — campaigns, leads, sequences, and mailboxes via API v2
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# ManyReach

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Script**: `scripts/manyreach-helper.sh [command] [subcommand] [options]`
- **API base**: `https://api.manyreach.com/api/v2`
- **Credential**: `MANYREACH_API_KEY` — set via `aidevops secret set MANYREACH_API_KEY`
- **Docs**: https://docs.manyreach.com
- **Strategy context**: `services/outreach/cold-outreach.md`
- **Verify connectivity**: `scripts/manyreach-helper.sh status`

## Core Commands

### Campaigns

- `manyreach-helper.sh campaigns list`
- `manyreach-helper.sh campaigns get <campaign_id>`
- `manyreach-helper.sh campaigns create --name "Q2 Outreach" --from-email sender@yourdomain.com`
- `manyreach-helper.sh campaigns pause <campaign_id>`
- `manyreach-helper.sh campaigns resume <campaign_id>`
- `manyreach-helper.sh campaigns delete <campaign_id>`
- `manyreach-helper.sh stats campaign <campaign_id>`

### Leads

- `manyreach-helper.sh leads list [--campaign <campaign_id>] [--page N]`
- `manyreach-helper.sh leads get <lead_id>`
- `manyreach-helper.sh leads unsubscribe <lead_id>`
- `manyreach-helper.sh leads import --campaign <campaign_id> --file prospects.csv`

Add a single lead:

```bash
manyreach-helper.sh leads add \
  --campaign <campaign_id> \
  --email prospect@company.com \
  --first-name Jane \
  --last-name Smith \
  --company "Acme Corp"
```

### Sequences

- `manyreach-helper.sh sequences list --campaign <campaign_id>`
- `manyreach-helper.sh sequences get <sequence_id>`

```bash
manyreach-helper.sh sequences add-step \
  --sequence <sequence_id> \
  --subject "Following up on my last email" \
  --body "Hi {{first_name}}, just wanted to check in..." \
  --delay-days 3
```

### Mailboxes

- `manyreach-helper.sh mailboxes list`
- `manyreach-helper.sh mailboxes get <mailbox_id>` — includes status, warmup, daily limits

All commands accept `--json` for raw API output (e.g., `campaigns list --json | jq '.data[].id'`).

## Operational Notes

### Sending Limits

Per-mailbox daily limits enforced. Check `mailboxes get <id>` for `daily_limit` and `sent_today`. Warmup ramp and hard cap (100/day): see `services/outreach/cold-outreach.md`.

### Personalisation

Merge tags in subject/body: `{{first_name}}`, `{{last_name}}`, `{{company}}`, `{{email}}`. Custom CSV fields also available as merge tags. Keep variation high across steps to reduce template fingerprinting.

### Reply Handling

Auto-stops sequences on any reply. Post-reply workflow:

1. Classify: positive, neutral, objection, or unsubscribe
2. Route positive/high-intent to human owner with SLA
3. Feed objection patterns back into copy and segmentation

### Compliance

- Physical postal address in every campaign email
- One-click unsubscribe mechanism required
- Honor opt-outs immediately — `leads unsubscribe <lead_id>`
- EU/UK contacts: document legitimate interest basis before sending

### CSV Import Format

Minimum columns: `email,first_name,last_name,company`. Additional custom fields pass through as merge tags.

```csv
email,first_name,last_name,company
jane@acme.com,Jane,Smith,Acme Corp
bob@example.com,Bob,Jones,Example Ltd
```

<!-- AI-CONTEXT-END -->

For platform selection, warmup strategy, and compliance baseline: `services/outreach/cold-outreach.md`.

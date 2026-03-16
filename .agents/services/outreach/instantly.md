---
description: Instantly v2 API operations - campaigns, leads, sequences, email accounts, warmup, and analytics
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

# Instantly API (v2)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Manage Instantly outbound infrastructure via API v2
- **Auth**: `Authorization: Bearer <INSTANTLY_API_KEY>`
- **Base URL**: `https://api.instantly.ai/api/v2`
- **Helper**: `scripts/instantly-helper.sh` (repo path: `.agents/scripts/instantly-helper.sh`)
- **Secret setup**: `aidevops secret set INSTANTLY_API_KEY`
- **Safe execution**: `aidevops secret run INSTANTLY_API_KEY -- instantly-helper.sh <command>`

## Core Commands

- `instantly-helper.sh campaigns list --status active --limit 20`
- `instantly-helper.sh campaigns get --campaign-id <campaign_id>`
- `instantly-helper.sh campaigns create --json-file ./campaign.json`
- `instantly-helper.sh leads list --campaign-id <campaign_id> --limit 50`
- `instantly-helper.sh leads create --json-file ./lead.json`
- `instantly-helper.sh sequences list --limit 20`
- `instantly-helper.sh warmup list`
- `instantly-helper.sh warmup enable --email-account-id <account_id>`
- `instantly-helper.sh analytics campaign --campaign-id <campaign_id>`

## Raw Endpoint Access

Use raw mode when an endpoint evolves faster than helper aliases:

```bash
instantly-helper.sh request --method GET --endpoint /campaigns
instantly-helper.sh request --method POST --endpoint /leads --json-file ./lead.json
```

## Payload Workflow

1. Prepare payload file (for example `campaign.json`, `lead.json`)
2. Validate JSON locally with `python3 -m json.tool <file>`
3. Execute helper command with `--json-file`
4. Keep payload templates in project docs, not in shared terminal history

## Warmup Operating Pattern

- List all email accounts or account warmup state with `warmup list`
- Enable warmup for newly connected inboxes before high-volume sends
- Disable warmup only after mailbox health and reply rates stabilize
- Pair warmup actions with cold-outreach guardrails from `services/outreach/cold-outreach.md`

## Troubleshooting

- **401/403**: verify `INSTANTLY_API_KEY` exists and is current
- **404**: endpoint/version mismatch; retry via `request --endpoint ...` and validate docs
- **422**: payload shape invalid; run `python3 -m json.tool` and confirm required fields
- **Rate limits**: reduce batch size (`--limit`) and stagger writes

## Related

- `services/outreach/cold-outreach.md` - policy and volume strategy
- `scripts/instantly-helper.sh` - command implementation
- `scripts/secret-helper.sh` - secret management patterns

<!-- AI-CONTEXT-END -->

---
description: Instantly v2 API - campaigns, leads, sequences, email accounts, warmup, and analytics
mode: subagent
tools:
  read: true
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Instantly API (v2)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Base URL**: `https://api.instantly.ai/api/v2`
- **Auth**: `Authorization: Bearer <INSTANTLY_API_KEY>`
- **Helper**: `scripts/instantly-helper.sh`
- **Secrets**: `aidevops secret set INSTANTLY_API_KEY`

## Core Commands

| Resource | Command |
|----------|---------|
| Campaigns | `instantly-helper.sh campaigns {list|get|create}` |
| Leads | `instantly-helper.sh leads {list|create} --campaign-id ID` |
| Sequences | `instantly-helper.sh sequences list` |
| Warmup | `instantly-helper.sh warmup {list|enable}` |
| Analytics | `instantly-helper.sh analytics campaign --campaign-id ID` |

## Raw Requests

```bash
instantly-helper.sh request --method GET --endpoint /campaigns
instantly-helper.sh request --method POST --endpoint /leads --json-file ./lead.json
```

Payload workflow: prepare JSON file → validate with `python3 -m json.tool <file>` → execute with `--json-file`.

## Warmup

- Check state with `warmup list`; enable for new inboxes before high-volume sends.
- Disable only after mailbox health and reply rates stabilize.
- Pair with cold-outreach guardrails from `services/outreach/cold-outreach.md`.

## Troubleshooting

- **401/403**: verify `INSTANTLY_API_KEY` exists and is current.
- **404**: endpoint/version mismatch — retry via `request --endpoint ...`.
- **422**: invalid payload — run `python3 -m json.tool`, confirm required fields.
- **Rate limits**: reduce `--limit`, stagger writes.

## Related

- `services/outreach/cold-outreach.md` — policy and volume strategy
- `scripts/instantly-helper.sh` — command implementation

<!-- AI-CONTEXT-END -->


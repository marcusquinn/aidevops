<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1511: Smartlead helper — campaigns, leads, sequences, warmup, analytics

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 3 cold outreach)
- **Conversation context:** Smartlead is a leading cold email platform with comprehensive REST API. Full API documentation fetched and analyzed in planning session.

## What

Create `scripts/smartlead-helper.sh` and `services/outreach/smartlead.md`:

1. `campaigns` — list, create, update status, delete
2. `sequences` — fetch, save (with A/B variants)
3. `leads` — add (batch 400), update, pause, resume, delete, unsubscribe, export CSV
4. `email-accounts` — list, create, update, add/remove from campaigns
5. `warmup` — configure warmup settings, fetch warmup stats
6. `analytics` — campaign statistics, date range analytics, global overview
7. `webhooks` — create, list, update, delete
8. `block-list` — add email/domain to global block list

API: REST at `https://server.smartlead.ai/api/v1`, API key auth via query parameter. Rate limit: 10 requests/2 seconds.

## Why

Smartlead is the most feature-complete cold outreach API. Automating campaign management enables AI-driven outreach at scale with proper warmup and compliance.

## How (Approach)

- Shell script following standard helper pattern
- curl for API calls with jq for JSON parsing
- API key stored via gopass: `aidevops secret set smartlead-api-key`
- Rate limiting: built-in delay between requests
- Config: `configs/smartlead-config.json.txt`

## Acceptance Criteria

- [ ] `scripts/smartlead-helper.sh` exists and passes ShellCheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/smartlead-helper.sh"
  ```
- [ ] `services/outreach/smartlead.md` exists with API reference
- [ ] All major endpoints covered: campaigns, leads, sequences, warmup, analytics
- [ ] Rate limiting implemented (10 req/2s)
- [ ] Credentials via gopass, never in output

## Dependencies

- **Blocked by:** t1510 (outreach strategy guidance)
- **Blocks:** none
- **External:** Smartlead account with API access

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 5h | Shell CLI + agent doc |
| Testing | 1.5h | Test against Smartlead API |
| **Total** | **6.5h** | |

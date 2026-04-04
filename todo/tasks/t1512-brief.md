<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1512: Instantly helper — campaigns, leads, sequences, warmup (v2 API)

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 3 cold outreach)
- **Conversation context:** Instantly is a major cold outreach platform with v2 API using Bearer token auth and REST standards.

## What

Create `scripts/instantly-helper.sh` and `services/outreach/instantly.md` covering Instantly API v2 endpoints for campaigns, leads, sequences, email accounts, warmup, and analytics.

## Why

Instantly is a popular alternative to Smartlead. Supporting both gives users flexibility and redundancy.

## How (Approach)

- Shell script following standard helper pattern
- Bearer token auth (more secure than Smartlead's query param approach)
- API key stored via gopass

## Acceptance Criteria

- [ ] `scripts/instantly-helper.sh` exists and passes ShellCheck
- [ ] `services/outreach/instantly.md` exists
- [ ] Bearer token authentication implemented
- [ ] Core endpoints: campaigns, leads, sequences, warmup

## Dependencies

- **Blocked by:** t1510 (outreach strategy)
- **External:** Instantly account with API v2 access

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 4.5h | Shell CLI + agent doc |
| Testing | 1h | Test against Instantly API |
| **Total** | **5.5h** | |

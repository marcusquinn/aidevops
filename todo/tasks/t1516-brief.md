<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1516: Outreach slash commands — /email-outreach, /email-campaign

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 3 cold outreach)

## What

Create slash command docs:
1. `/email-outreach` — launch cold outreach campaign (select platform, create campaign, add leads, configure warmup)
2. `/email-campaign` — manage newsletter/broadcast campaigns (list management, send, analytics)

## Why

Slash commands provide the user-facing entry point for email operations, following the framework's command pattern.

## How (Approach)

- Markdown command docs in `scripts/commands/`
- Follow existing command doc pattern (see `scripts/commands/email-health-check.md`)

## Acceptance Criteria

- [ ] `scripts/commands/email-outreach.md` exists
- [ ] `scripts/commands/email-campaign.md` exists

## Dependencies

- **Blocked by:** t1511 or t1512 (at least one outreach helper must exist)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 1.5h | Two command docs |
| **Total** | **1.5h** | |

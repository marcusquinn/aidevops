<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1515: LeadsForge helper — lead search and enrichment

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 3 cold outreach)

## What

Create `scripts/leadsforge-helper.sh` and `services/outreach/leadsforge.md` for lead search and enrichment via LeadsForge API (`api.leadsforge.ai/public/`).

## Why

Cold outreach needs qualified leads. LeadsForge provides a search engine for B2B leads with enrichment data.

## How (Approach)

- Shell script wrapping LeadsForge REST API
- API key stored via gopass

## Acceptance Criteria

- [ ] `scripts/leadsforge-helper.sh` exists and passes ShellCheck
- [ ] `services/outreach/leadsforge.md` exists
- [ ] Lead search and enrichment endpoints covered

## Dependencies

- **Blocked by:** t1510 (outreach strategy)
- **External:** LeadsForge account

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 3h | Shell CLI + agent doc |
| **Total** | **3h** | |

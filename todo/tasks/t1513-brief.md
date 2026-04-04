<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1513: ManyReach helper — campaigns, leads, sequences (v2 API)

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 3 cold outreach)

## What

Create `scripts/manyreach-helper.sh` and `services/outreach/manyreach.md` covering ManyReach API v2 endpoints.

## Why

ManyReach is another cold outreach option. Supporting multiple platforms prevents vendor lock-in.

## How (Approach)

- Shell script following standard helper pattern
- API at `https://api.manyreach.com/api`

## Acceptance Criteria

- [ ] `scripts/manyreach-helper.sh` exists and passes ShellCheck
- [ ] `services/outreach/manyreach.md` exists
- [ ] Core endpoints covered

## Dependencies

- **Blocked by:** t1510 (outreach strategy)
- **External:** ManyReach account with API access

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 4h | Shell CLI + agent doc |
| **Total** | **4h** | |

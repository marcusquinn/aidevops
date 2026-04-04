<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1514: Infraforge helper — domain/mailbox provisioning, DNS automation, IP management

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 3 cold outreach)

## What

Create `scripts/infraforge-helper.sh` and `services/outreach/infraforge.md` for private email infrastructure provisioning via Infraforge API. Covers domain purchasing, mailbox creation, DNS automation, IP management, and SSL/domain masking.

## Why

Cold outreach at scale requires dedicated sending infrastructure. Infraforge provides private servers with dedicated IPs — better deliverability control than shared infrastructure.

## How (Approach)

- Shell script wrapping Infraforge REST API (`api.infraforge.ai/public/`)
- API key stored via gopass

## Acceptance Criteria

- [ ] `scripts/infraforge-helper.sh` exists and passes ShellCheck
- [ ] `services/outreach/infraforge.md` exists with Infraforge vs Mailforge comparison
- [ ] Domain provisioning and mailbox creation endpoints covered

## Dependencies

- **Blocked by:** t1510 (outreach strategy)
- **External:** Infraforge account

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 4h | Shell CLI + agent doc |
| **Total** | **4h** | |

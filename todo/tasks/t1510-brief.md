<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1510: Cold outreach strategy agent doc — compliance, warmup, platform comparison

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 3 cold outreach)
- **Conversation context:** Cold B2B outreach requires dedicated guidance: warmup scaling, daily limits, compliance (CAN-SPAM, GDPR), platform selection, infrastructure decisions.

## What

Create `services/outreach/cold-outreach.md` agent doc and `services/outreach/` directory covering:

1. Warmup scaling: 5→20 emails/day ramp-up schedule
2. Daily limits: max 100 emails/day per mailbox (including follow-ups + replies)
3. Multi-mailbox rotation for higher volumes
4. Dedicated sending domains (never use primary business domain)
5. CAN-SPAM compliance: physical address, one-click unsubscribe (RFC 8058)
6. GDPR legitimate interest documentation
7. Platform comparison: Smartlead vs Instantly vs ManyReach feature/pricing matrix
8. Infrastructure decision: Infraforge (private/dedicated) vs Mailforge (shared) vs Primeforge (Google/MS365)
9. FluentCRM as alternative for WordPress-based outreach
10. Overused phrase avoidance in cold emails
11. B2B personalization patterns
12. Reply detection and conversation handoff

## Why

Cold outreach without compliance guidance risks legal liability and domain reputation damage. Without warmup and volume guidance, new sending domains get blacklisted immediately.

## How (Approach)

- Agent doc following standard pattern
- Create `services/outreach/` directory
- Reference Smartlead, Instantly, ManyReach API docs (fetched in planning session)
- Reference Infraforge/Mailforge comparison (fetched in planning session)

## Acceptance Criteria

- [ ] `services/outreach/cold-outreach.md` exists with AI-CONTEXT-START/END markers
  ```yaml
  verify:
    method: codebase
    pattern: "AI-CONTEXT-START"
    path: ".agents/services/outreach/cold-outreach.md"
  ```
- [ ] Warmup schedule documented
- [ ] Compliance requirements (CAN-SPAM, GDPR) documented
- [ ] Platform comparison matrix included

## Dependencies

- **Blocked by:** none
- **Blocks:** t1511-t1516 (all outreach helpers reference this guidance)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 3h | Write comprehensive strategy doc |
| **Total** | **3h** | |

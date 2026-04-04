<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1499: Update subagent-index.toon and AGENTS.md domain index for email system

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation)
- **Conversation context:** New email agent docs and helpers need to be registered in the framework's discovery indexes so agents can find them.

## What

Update:
1. `subagent-index.toon` — add entries for all new email service docs and outreach service docs
2. `AGENTS.md` domain index table — add Email and Outreach rows pointing to new docs
3. `.agents/AGENTS.md` (user guide) domain index — same updates

## Why

Without index updates, agents won't discover the new email capabilities. The subagent index is the primary discovery mechanism for on-demand agent loading.

## How (Approach)

- Edit `subagent-index.toon` to add new entries under `services/email/` and `services/outreach/`
- Edit both AGENTS.md files to update the domain index tables
- Follow existing entry patterns in the index

## Acceptance Criteria

- [ ] `subagent-index.toon` contains entries for email-mailbox, email-composition, email-intelligence, email-providers, email-security, email-actions, email-inbound-commands
  ```yaml
  verify:
    method: codebase
    pattern: "email-mailbox|email-composition|email-intelligence"
    path: ".agents/subagent-index.toon"
  ```
- [ ] `subagent-index.toon` contains entries for cold-outreach, smartlead, instantly, manyreach
- [ ] AGENTS.md domain index updated with new email and outreach entries

## Context & Decisions

- Outreach gets its own section in the index, separate from email services
- Index updates should happen after the docs they reference exist, but this task can be done incrementally

## Relevant Files

- `.agents/subagent-index.toon` — primary subagent discovery index
- `AGENTS.md` — developer guide domain index
- `.agents/AGENTS.md` — user guide domain index

## Dependencies

- **Blocked by:** t1492, t1497, t1498 (docs must exist before indexing)
- **Blocks:** none (but improves discoverability of everything else)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review current index structure |
| Implementation | 1h | Update three files |
| Testing | 15m | Verify entries resolve |
| **Total** | **1.5h** | |

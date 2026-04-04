<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1508: Email-to-action agent doc — todos, reports, opportunities, legal case files

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 actions)
- **Conversation context:** Emails trigger actions beyond replies: todos, calendar events, contact updates, report triage, legal case assembly. Need guidance doc for these patterns.

## What

Create `services/email/email-actions.md` agent doc covering:

1. Email→todo conversion patterns and when to create tasks
2. Report triage: SEO reports, expiry notifications, renewal considerations, optimization inspiration, genuine business opportunities
3. Source authentication for report emails (DNS checks, known sender validation)
4. Legal case file assembly: export email threads + attachments to PDF/txt, organize by folder/project, preserve chain of custody metadata
5. IMAP folders for archiving emails that could become projects/legal cases
6. Support/customer service communication: understanding receiver capabilities, escalation patterns
7. Newsletter-as-training-material: which newsletters to extract domain knowledge or email style examples from

## Why

Strategic guidance for the action bridge between email and the rest of the system. Without this, the triage engine and action scripts make inconsistent decisions.

## How (Approach)

- Agent doc following standard pattern
- Decision trees for: when to create a todo, when to flag for review, when to archive

## Acceptance Criteria

- [ ] `services/email/email-actions.md` exists with AI-CONTEXT-START/END markers
  ```yaml
  verify:
    method: codebase
    pattern: "AI-CONTEXT-START"
    path: ".agents/services/email/email-actions.md"
  ```
- [ ] Report triage guidance documented
- [ ] Legal case file assembly workflow documented
- [ ] Support communication escalation patterns documented

## Dependencies

- **Blocked by:** none
- **Blocks:** t1502 (triage references this), t1509 (legal case files)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 2.5h | Write comprehensive agent doc |
| **Total** | **2.5h** | |

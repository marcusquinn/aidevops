<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1497: Email mailbox agent doc — operations, shared mailboxes, organization

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation)
- **Conversation context:** Planning identified need for agent doc covering mailbox operations guidance that models may not already have — folder organization, category assignment, flagging taxonomy, shared mailbox workflows, archiving patterns.

## What

Create `services/email/email-mailbox.md` agent doc covering:

1. Mailbox organization: setting correct category (Primary, Transactions, Updates, Promotions, Junk/Spam)
2. Flagging taxonomy: Reminders, Tasks, Review, Filing, Ideas, Add-to-Contacts
3. Shared mailbox patterns: team triage, assignment routing, common addresses
4. Archiving rules: archive from inbox once replies sent and task complete, or flag if needing further attention
5. Threading guidance: when to reply in thread vs start afresh
6. Smart/sub mailbox creation for key contacts/projects/domains
7. Transaction receipt/invoice forwarding: detect and forward to accounts@ with phishing protection
8. Sieve rule patterns for auto-sorting on compatible servers
9. IMAP folder vs Gmail label differences
10. POP considerations for shared mailboxes

## Why

This is the guidance layer that makes the mailbox helper (t1493) intelligent. Without pre-defined guidance on organization, flagging, and shared mailbox workflows, the model would make inconsistent decisions. This doc is the "brain" that the helper script is the "hands" of.

## How (Approach)

- Agent doc following standard pattern (see `services/email/ses.md`)
- YAML frontmatter with tool declarations
- AI-CONTEXT-START/END markers for quick reference
- Decision trees for: category assignment, flag selection, thread vs new, archive vs flag

## Acceptance Criteria

- [ ] `services/email/email-mailbox.md` exists with AI-CONTEXT-START/END markers
  ```yaml
  verify:
    method: codebase
    pattern: "AI-CONTEXT-START"
    path: ".agents/services/email/email-mailbox.md"
  ```
- [ ] Category assignment decision tree documented
- [ ] Flagging taxonomy with clear definitions
- [ ] Shared mailbox workflow documented
- [ ] Threading decision tree (reply-in-thread vs new thread)
- [ ] Receipt/invoice forwarding rules with phishing checks

## Context & Decisions

- Flagging taxonomy chosen to cover the most common email actions: Reminders (time-sensitive), Tasks (action needed), Review (read carefully), Filing (archive to project), Ideas (inspiration), Add-to-Contacts (new contact)
- Transaction emails forwarded to accounts@ must pass phishing verification first
- Threading: reply in thread for ongoing conversation, new thread when topic changes or >30 days since last message

## Relevant Files

- `.agents/services/email/ses.md` — agent doc pattern to follow
- `.agents/services/email/email-agent.md` — existing email agent doc

## Dependencies

- **Blocked by:** none
- **Blocks:** t1505 (triage engine references this guidance)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review existing email agent docs |
| Implementation | 2h | Write comprehensive agent doc |
| Testing | 15m | Verify structure and completeness |
| **Total** | **2.5h** | |

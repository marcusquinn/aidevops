<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1495: Email composition helper — drafting, tone, signatures, attachments, legal awareness

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation)
- **Conversation context:** Planning identified need for intelligent email composition with draft-review-send workflow, tone calibration, signature injection, attachment handling, CC/BCC logic, and legal liability awareness.

## What

Create `scripts/email-compose-helper.sh` and `services/email/email-composition.md` agent doc. The helper provides:

1. `draft` — compose email with AI assistance, hold for user review before sending
2. `reply` — compose reply (auto-detect reply vs reply-all vs new thread)
3. `forward` — forward with optional commentary
4. `acknowledge` — send holding-pattern email (acknowledging receipt, managing expectations for full response)
5. `follow-up` — send follow-up when replying is delayed (confirm awareness, pending response)
6. `remind` — send reminder for things we asked for
7. `notify` — send project update notification

The agent doc covers:
- Tone calibration: formal ↔ casual detection based on recipient, context, and prior correspondence
- One-paragraph-per-sentence rule for readability
- Clear CTAs and numbered lists for questions/points
- Urgency flags (rarely appropriate)
- Overused phrase avoidance ("quick question", "just following up", "hope this finds you well")
- Legal liability awareness: distinguish what's agreed vs advised vs informational
- CC/BCC patterns: when to CC (transparency), BCC (privacy), reply-all vs 1:1
- Reply vs reply-all vs new thread decision tree
- Max 30MB attachments, file-share links for larger (PrivateBin for confidential)
- Email signature injection from user's configured signatures
- Screenshot attachment guidance (limit to relevant information)
- Support/customer service communication: understand receiver capabilities, seek escalation when appropriate

## Why

Raw email sending exists (SES, SMTP) but there's no intelligence layer for composition. Users need AI-assisted drafting with human review, appropriate tone, legal awareness, and workflow patterns (acknowledge → full reply → follow-up). This is where opus-tier writing quality matters most.

## How (Approach)

- Shell script for CLI interface, delegates to AI for composition via `ai-research` MCP tool
- Model routing: opus for important emails, sonnet for routine, haiku for acknowledgements
- Signature injection: read from Apple Mail signatures (t1494) or configured signature file
- Attachment handling: check size, warn at 25MB, block at 30MB, suggest file-share link
- Draft workflow: compose → write to temp file → open for review → send on approval
- Follow existing template system from `scripts/email-agent-helper.sh` but extend with AI composition

## Acceptance Criteria

- [ ] `scripts/email-compose-helper.sh` exists and passes ShellCheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/email-compose-helper.sh"
  ```
- [ ] `services/email/email-composition.md` exists with comprehensive guidance
  ```yaml
  verify:
    method: codebase
    pattern: "AI-CONTEXT-START"
    path: ".agents/services/email/email-composition.md"
  ```
- [ ] `draft` command produces email held for review (not auto-sent)
- [ ] `acknowledge` command sends holding-pattern response
- [ ] `follow-up` and `remind` commands with appropriate timing logic
- [ ] Attachment size check: warn at 25MB, block at 30MB
- [ ] Tone detection documented in agent doc
- [ ] Legal liability wording guidance in agent doc
- [ ] All functions use `local var="$1"` pattern and explicit returns

## Context & Decisions

- Opus for important composition, sonnet for routine — cost justified by quality difference in written communication
- Draft-and-hold is the default — AI should never auto-send without human review for non-template emails
- One-paragraph-per-sentence improves readability on mobile and in threading
- "Quick question" and similar overused phrases explicitly flagged for avoidance
- PrivateBin with self-destruct recommended for confidential attachments over plain email

## Relevant Files

- `.agents/services/email/email-agent.md` — existing template system
- `.agents/content/distribution/email.md` — subject line formulas, content strategy
- `.agents/tools/marketing/direct-response-copy/frameworks/email-sequences.md` — copywriting frameworks

## Dependencies

- **Blocked by:** t1493 (mailbox helper for reply context), t1494 (Apple Mail signatures)
- **Blocks:** t1505 (triage uses composition for auto-replies), t1510 (inbound commands need reply capability)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review existing template system, composition patterns |
| Implementation | 4h | Shell CLI + agent doc |
| Testing | 1h | Test draft workflow, tone detection |
| **Total** | **5.5h** | |

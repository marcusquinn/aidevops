<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1504: Inbound email command interface — permitted senders trigger aidevops tasks

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 2 actions)
- **Conversation context:** Email could be used by permitted senders to prompt the aidevops system to create todos, plans, or answer questions. Critical security: only permitted senders, mandatory prompt injection scanning.

## What

Create `scripts/email-inbound-command-helper.sh` and `services/email/email-inbound-commands.md`:

1. Poll configured mailbox for emails from permitted senders
2. Parse email body as task/question for aidevops
3. Mandatory prompt injection scanning before processing
4. Create todos/plans from email instructions
5. Answer questions about systems via email reply
6. Reject and log attempts from non-permitted senders
7. No executable attachments processed, ever

## Why

Email is a universal interface. Allowing permitted users to create tasks or ask questions via email extends aidevops accessibility beyond the terminal. But it's also an attack vector — security must be the primary concern.

## How (Approach)

- Shell script polling inbox via email-mailbox-helper.sh (t1493)
- Permitted sender allowlist in config (not hardcoded)
- prompt-guard-helper.sh scan on every email body before AI processing
- Task creation via claim-task-id.sh
- Reply via email-compose-helper.sh (t1495)

## Acceptance Criteria

- [ ] `scripts/email-inbound-command-helper.sh` exists and passes ShellCheck
- [ ] `services/email/email-inbound-commands.md` exists with security guidance
- [ ] Only processes emails from permitted senders (allowlist)
- [ ] Mandatory prompt injection scanning before AI processing
- [ ] No executable attachments opened
- [ ] Creates todos via claim-task-id.sh
- [ ] Replies to sender with confirmation

## Dependencies

- **Blocked by:** t1493 (mailbox helper), t1495 (composition for replies), t1498 (security rules)
- **Blocks:** none
- **External:** Configured mailbox, permitted sender list

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Implementation | 4h | Polling + security + task creation + reply |
| Testing | 1.5h | Test with permitted and non-permitted senders |
| **Total** | **5.5h** | |

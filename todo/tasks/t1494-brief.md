<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1494: Apple Mail integration via AppleScript

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation)
- **Conversation context:** macOS users with Apple Mail need native integration — AppleScript provides read, send, organize, signature extraction, smart mailbox creation, and attachment settings control.

## What

Create `scripts/apple-mail-helper.sh` — AppleScript bridge for Apple Mail on macOS. Commands:

1. `accounts` — list configured Apple Mail accounts
2. `inbox` — read messages from any mailbox (headers + body)
3. `send` — compose and send (with draft-and-hold option for user review)
4. `signatures` — list and extract email signatures for reuse
5. `smart-mailbox` — create smart mailboxes for key contacts/projects/domains
6. `organize` — move messages to correct category (Primary, Transactions, Updates, Promotions, Junk)
7. `flag` — set Apple Mail flags (colors map to: Reminders, Tasks, Review, Filing, Ideas, Add-to-Contacts)
8. `attachment-settings` — set image attachment size (Original or Large, as appropriate)
9. `archive` — archive messages from inbox once replies sent and task complete

## Why

Apple Mail is the default macOS email client. AppleScript provides deep integration that IMAP alone cannot: smart mailboxes, flag colors, attachment size settings, signature management, and native UI interaction. This complements the IMAP adapter (t1493) for users who prefer Apple Mail.

## How (Approach)

- Shell script wrapping `osascript` calls for AppleScript execution
- AppleScript for Apple Mail operations (Mail.app scripting dictionary)
- Signature extraction: read from `~/Library/Mail/V*/MailData/Signatures/`
- Smart mailbox creation via AppleScript `make new smart mailbox`
- Follow existing helper pattern from `scripts/ses-helper.sh`
- macOS-only — guard with platform check at script entry

## Acceptance Criteria

- [ ] `scripts/apple-mail-helper.sh` exists and passes ShellCheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/apple-mail-helper.sh"
  ```
- [ ] Platform guard: exits with clear message on non-macOS
- [ ] `signatures` command extracts signatures from Apple Mail data directory
- [ ] `smart-mailbox` command creates smart mailboxes via AppleScript
- [ ] `send` command supports `--draft` flag to hold for user review before sending
- [ ] `attachment-settings` command can set image size to Original or Large
- [ ] All functions use `local var="$1"` pattern and explicit returns

## Context & Decisions

- AppleScript is macOS-only — this helper is explicitly platform-specific
- Signature files are in `~/Library/Mail/V*/MailData/Signatures/` as HTML
- Apple Mail smart mailboxes use predicate-based rules (similar to Spotlight queries)
- Draft-and-hold is critical for AI-composed emails that need human review

## Relevant Files

- `.agents/scripts/ses-helper.sh` — CLI structure pattern
- `~/Library/Mail/V*/MailData/Signatures/` — Apple Mail signature storage

## Dependencies

- **Blocked by:** none (can be built in parallel with t1493)
- **Blocks:** t1509 (contact sync via AppleScript), t1511 (calendar event creation)
- **External:** macOS with Apple Mail configured

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Apple Mail scripting dictionary, signature file format |
| Implementation | 4h | Shell CLI + AppleScript commands |
| Testing | 1h | Test on macOS with real Apple Mail account |
| **Total** | **6h** | |

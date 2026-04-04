<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1493: Email mailbox helper — IMAP/JMAP adapter and mailbox operations

## Origin

- **Created:** 2026-03-16
- **Session:** opencode:email-system-planning
- **Created by:** human + ai-interactive
- **Parent task:** none (Phase 1 foundation)
- **Conversation context:** Planning session identified the core architectural gap: no mailbox client layer to read real email accounts. SES receive is S3-only, not a mailbox client.

## What

Create `scripts/email-mailbox-helper.sh` — the foundational mailbox client that connects to any email provider via IMAP (with JMAP and Graph API adapters planned for later tasks). Commands:

1. `accounts` — list configured accounts, test connectivity
2. `inbox` — fetch message list (headers only, no body download by default), search, read specific message
3. `folders` — list, create, subscribe, show folder name mappings per provider
4. `send` — compose and send via SMTP (delegates to email-compose-helper for intelligence)
5. `move` — move messages between folders (archive, categorize)
6. `flag` — set/clear flags: Reminders, Tasks, Review, Filing, Ideas, Add-to-Contacts
7. `search` — IMAP SEARCH with provider-aware syntax, Spotlight/notmuch fallback for attachment search
8. `smart-mailbox` — create Apple Mail smart mailboxes or IMAP sub-folders for key contacts/projects/domains

SQLite metadata index at `~/.aidevops/.agent-workspace/email-mailbox/index.db` — stores message-id, date, from, to, subject, flags, classification. Never caches full message bodies (privacy, disk space, staleness).

Uses BODY.PEEK (doesn't mark as read). Respects 600 permissions on all local data.

## Why

This is the foundation layer. Every other email capability (triage, composition, actions, outreach reply detection) needs the ability to read a mailbox. The existing SES receive via S3 is a webhook pattern, not a mailbox client — you can't browse folders, search, or manage read/unread state.

## How (Approach)

- Shell script following standard `[service]-helper.sh` pattern
- Python subprocess for IMAP operations (Python `imaplib` + `email` stdlib are robust and available everywhere)
- Create `scripts/email_imap_adapter.py` for IMAP connection, FETCH, SEARCH, STORE operations
- Read provider configs from `configs/email-providers.json` (created in t1492)
- Credentials via gopass: `aidevops secret set email-imap-{account}`
- Follow patterns from `scripts/ses-helper.sh` for CLI structure
- Follow patterns from `scripts/email_parser.py` for MIME parsing (reuse existing)

## Acceptance Criteria

- [ ] `scripts/email-mailbox-helper.sh` exists and passes ShellCheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/email-mailbox-helper.sh"
  ```
- [ ] `scripts/email_imap_adapter.py` exists and handles IMAP connect, fetch headers, fetch body, search, move, flag
  ```yaml
  verify:
    method: codebase
    pattern: "def (connect|fetch_headers|fetch_body|search|move_message|set_flag)"
    path: ".agents/scripts/email_imap_adapter.py"
  ```
- [ ] `accounts` command lists configured accounts and tests IMAP connectivity
- [ ] `inbox` command fetches message headers without downloading bodies
- [ ] `folders` command lists folders with provider-aware name mapping
- [ ] `flag` command supports custom flag categories
- [ ] SQLite index stores metadata only, never message bodies
  ```yaml
  verify:
    method: codebase
    pattern: "body"
    path: ".agents/scripts/email_imap_adapter.py"
    expect: absent
  ```
- [ ] All functions use `local var="$1"` pattern and explicit returns
- [ ] Credentials never appear in output or logs

## Context & Decisions

- IMAP first, JMAP adapter in Phase 4 (t1525) — IMAP is universal, JMAP is Fastmail-only for now
- Python for IMAP operations because imaplib is robust and the existing email_parser.py provides MIME parsing
- SQLite metadata index avoids re-fetching headers on every operation but never caches bodies
- BODY.PEEK prevents marking messages as read during automated scanning
- macOS Spotlight integration deferred to t1527 (Phase 4)

## Relevant Files

- `.agents/scripts/ses-helper.sh` — CLI structure pattern to follow
- `.agents/scripts/email_parser.py` — existing MIME parsing to reuse
- `.agents/scripts/email-agent-helper.sh` — existing email helper pattern (mission-scoped)
- `.agents/configs/email-providers.json.txt` — provider configs (t1492)

## Dependencies

- **Blocked by:** t1492 (provider configs)
- **Blocks:** t1495 (composition helper), t1505 (triage engine), t1506 (voice mining), t1510 (inbound commands)
- **External:** IMAP credentials for at least one test account

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review imaplib patterns, existing email_parser.py |
| Implementation | 5h | Shell CLI + Python IMAP adapter + SQLite schema |
| Testing | 1.5h | Test against real IMAP account, verify flag operations |
| **Total** | **7h** | |

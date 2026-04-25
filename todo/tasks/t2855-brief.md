---
mode: subagent
---

# t2855: IMAP polling routine + `mailboxes.json` registry

## Pre-flight

- [x] Memory recall: `imap polling fetch email` → no relevant lessons; existing `email-providers.json.txt` has IMAP host metadata
- [x] Discovery: 15 providers documented at `email-providers.json.txt`; no polling implementation yet
- [x] File refs verified: `.agents/configs/email-providers.json.txt`, `.agents/configs/email-sieve-config.json.txt`
- [x] Tier: `tier:standard` — IMAP IDLE + `email-ingest-helper.sh` from t2854 are the building blocks

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P5 (email channel)

## What

A pulse-driven routine that polls configured IMAP mailboxes, fetches new messages, drops them as `.eml` files into `_knowledge/inbox/`, and lets the existing ingestion + review-gate flow handle the rest. New `mailboxes.json` registry per repo and per personal plane configures which mailboxes to poll, with credentials stored in `gopass`.

**Concrete deliverables:**

1. `_config/mailboxes.json` (per-repo) and `~/.aidevops/configs/mailboxes.json` (personal plane) — registry of mailboxes to poll
2. `scripts/email-poll-helper.sh tick` — pulse-driven routine: for each mailbox, fetch new messages since last-seen UID, drop as `.eml` to inbox
3. Per-mailbox state at `_knowledge/.imap-state.json`: `{<mailbox-id>: {last_uid_seen, last_polled_at, last_error?}}`
4. Credentials via gopass: `gopass aidevops/email/<mailbox-id>/password` (never inline in `mailboxes.json`)
5. Routine `r044` in `TODO.md`, repeat: `cron(*/10 * * * *)` (every 10 min), run: `scripts/email-poll-helper.sh tick`
6. CLI: `aidevops email mailbox add|remove|list|test`
7. Backfill mode: `--since <date>` for first-time setup of an existing mailbox without dumping all history

## Why

Email arrives 24/7; the human is not always at the keyboard. Without polling, every message has to be hand-saved as `.eml`. With polling, the case workflow can react to incoming mail in near-real-time (10 min latency, sufficient for dispute/contract correspondence — shorter latency is theatre).

Storing credentials in gopass (not in `mailboxes.json`) keeps the registry git-trackable while secrets stay encrypted. Per-mailbox state at `_knowledge/.imap-state.json` lets polling resume cleanly across pulse restarts.

## How (Approach)

1. **`mailboxes.json` schema**:
   ```json
   {
     "mailboxes": [
       {
         "id": "personal-icloud",
         "provider": "icloud",
         "host": "imap.mail.me.com",
         "port": 993,
         "user": "marcus@example.com",
         "password_ref": "aidevops/email/personal-icloud/password",
         "folders": ["INBOX", "Cases/2026"],
         "since": "2026-01-01"
       }
     ]
   }
   ```
2. **Poll helper** — Python script `scripts/email_poll.py` using `imaplib` (stdlib):
   - For each configured mailbox: connect, login, select folder
   - `UID FETCH <last+1>:* (RFC822 UID)` to get new messages since last-seen UID
   - For each fetched message: write `.eml` to `_knowledge/inbox/email-<mailbox-id>-<uid>.eml`
   - Update state with new high-watermark UID
   - Bash wrapper `email-poll-helper.sh tick` orchestrates iteration over all mailboxes, error handling, lock-protection
3. **Credential resolution** — `_resolve_password(password_ref)`:
   - If `password_ref` starts with `gopass:` → call `gopass show <path>` (silent, no echo)
   - Otherwise treat as a literal env-var name to look up
   - Never log resolved password value
4. **CLI surface** — `aidevops email mailbox`:
   - `add` — interactive: prompt for provider (auto-fill host/port from `email-providers.json.txt`), user, gopass path; tests connection
   - `list` — table of mailboxes with last-polled-at, last-error
   - `test <id>` — fetch 1 message without committing state (dry-run)
   - `remove <id>` — un-register
5. **Routine `r044`** — pulse picks it up; lock-protected (one poll per cycle); errors fail open (log + continue, don't crash pulse)
6. **First-time backfill** — `email-poll-helper.sh backfill <mailbox-id> --since <date>`: bypass last-seen UID, fetch from `--since`; rate-limited to avoid IMAP-server abuse (e.g. 100 messages per minute)
7. **Tests** — covers tick happy path, missing credentials handling, IMAP connection failure (graceful), state persistence across runs, backfill with date filter, dry-run test mode

### Files Scope

- NEW: `.agents/scripts/email_poll.py`
- NEW: `.agents/scripts/email-poll-helper.sh`
- NEW: `.agents/templates/mailboxes-config.json` (default `_config/mailboxes.json`)
- EDIT: `.agents/cli/aidevops` (add `email mailbox` subcommand group)
- EDIT: `TODO.md` (add `r044` routine entry — done in this task's PR)
- NEW: `.agents/tests/test-email-poll.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (IMAP polling section)

## Acceptance Criteria

- [ ] `aidevops email mailbox add` interactive flow registers a new mailbox with credentials from gopass
- [ ] `email-poll-helper.sh tick` fetches new messages from a configured IMAP mailbox and writes `.eml` files to inbox
- [ ] Subsequent ticks fetch only messages newer than last-seen UID (no duplicates)
- [ ] `aidevops email mailbox test <id>` performs a dry-run fetch (1 message), does not commit state
- [ ] Failed connection (wrong password): logs error, continues; does not crash pulse
- [ ] Multiple folders per mailbox: each polled independently with its own state
- [ ] Backfill mode `--since 2026-01-01` fetches historical messages without spamming the server (rate-limited)
- [ ] `aidevops email mailbox list` shows last-polled-at + last-error per mailbox
- [ ] Credentials never appear in any log file or `mailboxes.json` (verifiable by grep)
- [ ] Routine `r044` runs every 10 min, lock-protected
- [ ] ShellCheck zero violations; Python `py_compile` passes
- [ ] Tests pass: `bash .agents/tests/test-email-poll.sh`
- [ ] Documentation: IMAP setup guide in `.agents/aidevops/knowledge-plane.md`

## Dependencies

- **Blocked by:** t2854 (P5a — `.eml` ingestion handler that this routine drops files for)
- **Soft-blocked by:** none (gopass and IMAP infrastructure already exist)
- **Blocks:** t2856 (P5c — thread reconstruction needs a stream of polled messages to demonstrate threading)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Email channel" → IMAP routine
- Existing config: `.agents/configs/email-providers.json.txt` (provider host/port/auth metadata)
- gopass usage pattern: `prompts/build.txt` § "Secret-handling rules"
- Python imaplib examples: stdlib documentation; UIDPLUS extension for stable UIDs

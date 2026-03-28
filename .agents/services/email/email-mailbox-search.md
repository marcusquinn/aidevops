---
description: Mailbox search using OS-level indexes — macOS Spotlight (mdfind) and Linux notmuch/mu. Full-text search including attachment content.
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

# Email Mailbox Search

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Helper**: `scripts/mailbox-search-helper.sh`
- **macOS**: Spotlight via `mdfind` — no setup, indexes Mail.app and attachments automatically
- **Linux**: `notmuch` or `mu` — requires maildir sync + index initialization
- **Attachment search**: PDF, DOCX, TXT content searchable on Spotlight; filename-only on notmuch; MIME-type on mu
- **Related**: `services/email/email-mailbox.md` (IMAP/JMAP operations), `scripts/email-mailbox-helper.sh`

<!-- AI-CONTEXT-END -->

## Backend Selection

| Backend | Platform | Setup | Attachment Search | Query Language |
|---------|----------|-------|-------------------|----------------|
| **Spotlight** | macOS only | None (built-in) | PDF, Office, text (content) | `mdfind` boolean |
| **notmuch** | macOS + Linux | `notmuch new` | Filename only | Rich: `from:`, `subject:`, `date:`, `tag:` |
| **mu** | macOS + Linux | `mu init && mu index` | MIME type filter | Rich: `from:`, `subject:`, `date:`, `mime:` |

**Auto-detection order**: Spotlight (macOS) → notmuch → mu → error. notmuch preferred for power users/Linux (requires local maildir via `mbsync`/`offlineimap`). mu is the alternative with better Emacs integration (mu4e).

## Usage

```bash
mailbox-search-helper.sh search "project proposal"                                    # auto-detect
mailbox-search-helper.sh search "invoice Q1 2026" --backend spotlight
mailbox-search-helper.sh search "from:alice@example.com subject:contract" --backend notmuch
mailbox-search-helper.sh search "from:alice date:20260101..20260401" --backend mu
mailbox-search-helper.sh search-attachments "NDA agreement" --type pdf
mailbox-search-helper.sh search-attachments "quarterly report" --type all
mailbox-search-helper.sh index-status
mailbox-search-helper.sh setup --backend notmuch --maildir ~/Maildir
mailbox-search-helper.sh setup --backend mu --maildir ~/Mail
```

## Output Format

All backends return JSON arrays. Fields: `path`, `subject`, `from`, `date`, `backend`. notmuch adds: `id`, `tags`, `matched`, `total`, `files`.

```json
[{"path": "/Users/alice/Library/Mail/V10/.../message.emlx", "subject": "Q1 Invoice - Project Alpha", "from": "billing@vendor.com", "date": "2026-03-01 09:15:00 +0000", "backend": "spotlight"}]
```

## Spotlight (macOS)

Indexes Mail.app `.emlx` and standalone `.eml` files — headers, body, and attachment content (PDF, Office, plain text). Does **not** index encrypted attachments or binary formats without a registered importer. Requires Mail.app local sync; index rebuild after large imports can take minutes to hours.

### Query Syntax

```bash
mdfind "kMDItemContentType == 'com.apple.mail.emlx' && kMDItemTextContent == '*invoice*'cdw"
mdfind "kMDItemAuthorEmailAddresses == '*alice@example.com*'"
mdfind "kMDItemSubject == '*project proposal*'cdw"
mdfind "kMDItemContentCreationDate >= $time.iso(2026-01-01T00:00:00Z)"
mdfind "kMDItemTextContent == '*NDA*'cdw && kMDItemContentType == 'com.adobe.pdf'"
```

Modifiers: `c` = case-insensitive, `d` = diacritic-insensitive, `w` = word-based.

### Index Health

```bash
mdutil -s /                                                        # Check status
sudo mdutil -E /                                                   # Re-index (slow)
mdfind "kMDItemContentType == 'com.apple.mail.emlx'" | wc -l      # Message count
```

## notmuch

### Setup

```bash
brew install isync   # macOS
apt install isync    # Linux
mbsync -a            # Sync IMAP to maildir (configure ~/.mbsyncrc first)
mailbox-search-helper.sh setup --backend notmuch --maildir ~/Maildir
# Manual: notmuch config set database.path ~/Maildir && notmuch new
```

### Query Language

```bash
notmuch search "from:alice@example.com"
notmuch search "subject:invoice"
notmuch search "date:2026-01-01..2026-03-31"              # also: date:1month..today
notmuch search "from:alice AND subject:contract"           # AND, OR, NOT supported
notmuch search "tag:inbox AND tag:unread"
notmuch search "attachment:*.pdf"
```

### Tags and Indexing

```bash
notmuch tag +inbox +unread -- "from:alice@example.com"
notmuch tag -inbox -- "tag:inbox AND date:..1month"
notmuch search --output=tags '*'
notmuch new   # Run after mbsync; automate: */15 * * * * mbsync -a && notmuch new --quiet
```

## mu

### Setup

```bash
brew install mu              # macOS
apt install maildir-utils    # Linux
mailbox-search-helper.sh setup --backend mu --maildir ~/Maildir
# Manual: mu init --maildir=~/Maildir && mu index
```

### Query Language

```bash
mu find "from:alice@example.com"
mu find "subject:invoice"
mu find "date:20260101..20260401"
mu find "mime:application/pdf"                             # MIME type filter
mu find "flag:attach"
mu find --format=json "subject:contract"
mu index   # Run after new messages arrive; automate with mbsync post-sync hook
```

## Attachment Content Search

| Backend | Coverage | Command |
|---------|----------|---------|
| **Spotlight** | PDF, Word, Excel, PowerPoint, TXT, RTF, CSV, MD (content) | `mailbox-search-helper.sh search-attachments "NDA" --type pdf --backend spotlight` |
| **notmuch** | Filename only | `mailbox-search-helper.sh search-attachments "invoice" --type pdf --backend notmuch` |
| **mu** | MIME type filter | `mailbox-search-helper.sh search-attachments "contract" --type pdf --backend mu` |

For notmuch attachment content search, extract attachments and use a separate full-text indexer (e.g., recoll).

## Integration with email-mailbox-helper.sh

Use `email-mailbox-helper.sh search` for live IMAP server state; use `mailbox-search-helper.sh` for fast offline indexed search with attachment content.

```bash
email-mailbox-helper.sh search myaccount --query "SUBJECT invoice SINCE 01-Jan-2026"  # IMAP live
mailbox-search-helper.sh search "invoice Q1 2026" --backend spotlight                  # indexed
```

## Troubleshooting

| Problem | Steps |
|---------|-------|
| **Spotlight: no results** | `mdutil -s /` (indexing enabled?) → verify Mail.app local sync → `mdfind "kMDItemContentType == 'com.apple.mail.emlx'" \| wc -l` (count=0? `sudo mdutil -E /`) → check `.eml` not excluded in Privacy settings |
| **notmuch: no results** | `notmuch config get database.path` (correct?) → `ls ~/Maildir/` (has messages?) → `notmuch new` → `notmuch count` / `notmuch search '*'` |
| **mu: no results** | `mu info` (database ok?) → `ls ~/Maildir/` (has messages?) → `mu index` → `mu find '*'` |
| **Attachment content not found** | Spotlight: `mdimport -L` (check importers). notmuch: content not indexed, filename only. mu: MIME type filter only, not full-text. |

## Related

- `services/email/email-mailbox.md` — IMAP/JMAP mailbox operations, smart mailboxes, Sieve rules
- `scripts/email-mailbox-helper.sh` — IMAP/JMAP operations helper (t1493)
- `scripts/mailbox-search-helper.sh` — this helper
- `services/email/email-agent.md` — autonomous email communication

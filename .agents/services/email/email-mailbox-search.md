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

**Auto-detection order**: Spotlight (macOS) → notmuch → mu → error.

- **Spotlight** — default on macOS. No config. Indexes Mail.app `.emlx` and standalone `.eml` files. Attachment content (PDF, Office, text) indexed by OS.
- **notmuch** — preferred for power users/Linux. Requires local maildir (sync via `mbsync`/`offlineimap`). Rich query language; attachment filename search only.
- **mu** — alternative to notmuch. MIME type filtering. Better Emacs integration (mu4e).

## Usage

```bash
# Auto-detect backend and search
mailbox-search-helper.sh search "project proposal"

# Spotlight (macOS)
mailbox-search-helper.sh search "invoice Q1 2026" --backend spotlight

# notmuch with query syntax
mailbox-search-helper.sh search "from:alice@example.com subject:contract" --backend notmuch

# mu with date range
mailbox-search-helper.sh search "from:alice date:20260101..20260401" --backend mu

# Search attachment content (PDF)
mailbox-search-helper.sh search-attachments "NDA agreement" --type pdf

# Search all attachment types
mailbox-search-helper.sh search-attachments "quarterly report" --type all

# Check index status
mailbox-search-helper.sh index-status

# Set up notmuch
mailbox-search-helper.sh setup --backend notmuch --maildir ~/Maildir

# Set up mu
mailbox-search-helper.sh setup --backend mu --maildir ~/Mail
```

## Output Format

All search commands return a JSON array:

```json
[
  {
    "path": "/Users/alice/Library/Mail/V10/.../message.emlx",
    "subject": "Q1 Invoice - Project Alpha",
    "from": "billing@vendor.com",
    "date": "2026-03-01 09:15:00 +0000",
    "backend": "spotlight"
  }
]
```

notmuch results include additional fields (`id`, `tags`, `matched`, `total`, `files`):

```json
[
  {
    "id": "thread:0000000000000001",
    "subject": "Q1 Invoice - Project Alpha",
    "from": "billing@vendor.com",
    "date": "3 days ago",
    "tags": ["inbox", "unread"],
    "matched": 1,
    "total": 3,
    "files": ["/home/alice/Maildir/new/1234567890.msg"],
    "backend": "notmuch"
  }
]
```

## Spotlight (macOS)

Indexes Mail.app `.emlx` files and standalone `.eml` files. Includes headers, body, and attachment content (PDF text, Office docs, plain text). Does **not** index encrypted attachments or binary formats without a registered importer.

### Query Syntax

```bash
# Email body text
mdfind "kMDItemContentType == 'com.apple.mail.emlx' && kMDItemTextContent == '*invoice*'cdw"

# Sender
mdfind "kMDItemAuthorEmailAddresses == '*alice@example.com*'"

# Subject
mdfind "kMDItemSubject == '*project proposal*'cdw"

# Date range
mdfind "kMDItemContentCreationDate >= $time.iso(2026-01-01T00:00:00Z)"

# Attachment content (PDF)
mdfind "kMDItemTextContent == '*NDA*'cdw && kMDItemContentType == 'com.adobe.pdf'"
```

Modifiers: `c` = case-insensitive, `d` = diacritic-insensitive, `w` = word-based.

### Index Health

```bash
mdutil -s /                                                        # Check status
sudo mdutil -E /                                                   # Re-index (slow)
mdfind "kMDItemContentType == 'com.apple.mail.emlx'" | wc -l      # Message count
```

**Limitations**: macOS only; requires Mail.app local sync; no boolean query language as rich as notmuch/mu; index rebuild after large imports can take minutes to hours.

## notmuch

### Setup

```bash
brew install isync   # macOS
apt install isync    # Linux
mbsync -a            # Sync IMAP to maildir (configure ~/.mbsyncrc first)

# Initialize via helper or manually:
mailbox-search-helper.sh setup --backend notmuch --maildir ~/Maildir
# Manual: notmuch config set database.path ~/Maildir && notmuch new
```

### Query Language

```bash
notmuch search "from:alice@example.com"
notmuch search "subject:invoice"
notmuch search "date:1month..today"
notmuch search "date:2026-01-01..2026-03-31"
notmuch search "from:alice AND subject:contract"
notmuch search "from:alice OR from:bob"
notmuch search "invoice NOT spam"
notmuch search "tag:inbox AND tag:unread"
notmuch search "attachment:*.pdf"
notmuch search "from:billing@vendor.com subject:invoice date:2026.."
```

### Tags

```bash
notmuch tag +inbox +unread -- "from:alice@example.com"
notmuch tag -inbox -- "tag:inbox AND date:..1month"
notmuch search --output=tags '*'
```

### Incremental Indexing

```bash
notmuch new   # Run after mbsync
# Automate: */15 * * * * mbsync -a && notmuch new --quiet
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
mu find "mime:application/pdf"
mu find "mime:application/vnd.openxmlformats-officedocument.wordprocessingml.document"
mu find "flag:attach"
mu find "from:billing@vendor.com subject:invoice date:20260101.."
mu find --format=json "subject:contract"
```

### Incremental Indexing

```bash
mu index   # Run after new messages arrive
# Automate with mbsync post-sync hook
```

## Attachment Content Search

| Backend | Coverage | Command |
|---------|----------|---------|
| **Spotlight** | PDF, Word, Excel, PowerPoint, TXT, RTF, CSV, MD (content) | `mailbox-search-helper.sh search-attachments "NDA" --type pdf --backend spotlight` |
| **notmuch** | Filename only | `mailbox-search-helper.sh search-attachments "invoice" --type pdf --backend notmuch` |
| **mu** | MIME type filter | `mailbox-search-helper.sh search-attachments "contract" --type pdf --backend mu` |

For notmuch attachment content search, extract attachments and use a separate full-text indexer (e.g., recoll).

## Integration with email-mailbox-helper.sh

| Tool | When to use |
|------|-------------|
| `email-mailbox-helper.sh search` | IMAP SEARCH — live server state, no local index |
| `mailbox-search-helper.sh search` | OS-level indexed — fast, offline, attachment content |

```bash
# IMAP (server-side, live)
email-mailbox-helper.sh search myaccount --query "SUBJECT invoice SINCE 01-Jan-2026"

# OS-level (indexed, fast, attachment content)
mailbox-search-helper.sh search "invoice Q1 2026" --backend spotlight
```

## Troubleshooting

### Spotlight Returns No Results

1. `mdutil -s /` — confirm indexing enabled
2. Verify Mail.app has downloaded messages locally (not IMAP-only)
3. `mdfind "kMDItemContentType == 'com.apple.mail.emlx'" | wc -l` — check count
4. Count is 0: `sudo mdutil -E /` (takes time)
5. `.eml` files: verify not excluded in Privacy settings

### notmuch Returns No Results

1. `notmuch config get database.path` — check path
2. `ls ~/Maildir/` — verify maildir has messages
3. `notmuch new` — re-index
4. `notmuch count` / `notmuch search '*'` — test

### mu Returns No Results

1. `mu info` — check database
2. `ls ~/Maildir/` — verify maildir
3. `mu index` — re-index
4. `mu find '*'` — test

### Attachment Content Not Found

- **Spotlight**: check importers with `mdimport -L`
- **notmuch**: attachment content not indexed — filename search only
- **mu**: MIME type filter only — not full-text content

## Related

- `services/email/email-mailbox.md` — IMAP/JMAP mailbox operations, smart mailboxes, Sieve rules
- `scripts/email-mailbox-helper.sh` — IMAP/JMAP operations helper (t1493)
- `scripts/mailbox-search-helper.sh` — this helper
- `services/email/email-agent.md` — autonomous email communication

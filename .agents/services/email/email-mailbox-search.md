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
- **Attachment search**: PDF, DOCX, TXT content searchable on all backends
- **Related**: `services/email/email-mailbox.md` (IMAP/JMAP operations), `scripts/email-mailbox-helper.sh` (mailbox helper)

**Key principle**: Leverage OS-level indexes rather than building custom search. Spotlight indexes attachment content natively on macOS. notmuch and mu provide rich query languages for maildir-based setups.

<!-- AI-CONTEXT-END -->

## Backend Selection

| Backend | Platform | Setup | Attachment Search | Query Language |
|---------|----------|-------|-------------------|----------------|
| **Spotlight** | macOS only | None (built-in) | PDF, Office, text | `mdfind` boolean |
| **notmuch** | macOS + Linux | `notmuch new` | Filename only | Rich: `from:`, `subject:`, `date:`, `tag:` |
| **mu** | macOS + Linux | `mu init && mu index` | MIME type filter | Rich: `from:`, `subject:`, `date:`, `mime:` |

**Auto-detection order**: Spotlight (macOS) → notmuch → mu → error.

### When to Use Each Backend

**Spotlight** — default on macOS. No configuration. Indexes Mail.app messages and all `.eml` files. Attachment content (PDF text, Office documents, plain text) is indexed automatically by the OS. Best for users with Mail.app.

**notmuch** — preferred for power users and Linux. Requires a local maildir (sync via `mbsync` or `offlineimap`). Excellent query language with boolean operators, date ranges, and tag support. Attachment filename search only (not content).

**mu** — alternative to notmuch. Similar capabilities. Better integration with Emacs (mu4e). MIME type filtering for attachment search.

## Usage

```bash
# Auto-detect backend and search
mailbox-search-helper.sh search "project proposal"

# Spotlight search (macOS)
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

# Set up mu with custom maildir
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

notmuch results include additional fields:

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

## Spotlight Deep Dive (macOS)

### How Spotlight Indexes Email

Spotlight indexes Mail.app messages stored as `.emlx` files in `~/Library/Mail/`. It also indexes standalone `.eml` files anywhere on disk. The index includes:

- Message headers (subject, from, to, date)
- Message body text
- Attachment content: PDF text layers, Office document text, plain text files

Spotlight does **not** index encrypted attachments or binary formats without a registered importer.

### Spotlight Query Syntax

`mdfind` uses a subset of the Spotlight query language:

```bash
# Search email body text
mdfind "kMDItemContentType == 'com.apple.mail.emlx' && kMDItemTextContent == '*invoice*'cdw"

# Search by sender (Mail.app metadata)
mdfind "kMDItemAuthorEmailAddresses == '*alice@example.com*'"

# Search by subject
mdfind "kMDItemSubject == '*project proposal*'cdw"

# Date range (epoch timestamps)
mdfind "kMDItemContentCreationDate >= $time.iso(2026-01-01T00:00:00Z)"

# Attachment content search (PDF, Office, text)
mdfind "kMDItemTextContent == '*NDA*'cdw && kMDItemContentType == 'com.adobe.pdf'"
```

Modifiers: `c` = case-insensitive, `d` = diacritic-insensitive, `w` = word-based.

### Spotlight Index Health

```bash
# Check indexing status
mdutil -s /

# Re-index if needed (requires sudo)
sudo mdutil -E /

# Check Mail.app message count in index
mdfind "kMDItemContentType == 'com.apple.mail.emlx'" | wc -l
```

### Spotlight Limitations

- macOS only
- Requires Mail.app or `.eml` files on disk (IMAP-only without local sync is not indexed)
- Attachment content requires Spotlight importers (PDF, Office are built-in; custom formats may not be indexed)
- No boolean query language as rich as notmuch/mu
- Index rebuild after large imports can take minutes to hours

## notmuch Deep Dive

### Setup

notmuch requires a local maildir. Sync IMAP to maildir first:

```bash
# Install mbsync (isync) for IMAP sync
brew install isync  # macOS
apt install isync   # Linux

# Configure ~/.mbsyncrc (see email-mailbox.md for IMAP config)
# Then sync:
mbsync -a

# Initialize notmuch
mailbox-search-helper.sh setup --backend notmuch --maildir ~/Maildir

# Or manually:
notmuch config set database.path ~/Maildir
notmuch new
```

### notmuch Query Language

notmuch uses a powerful query language based on Xapian:

```bash
# From a specific sender
notmuch search "from:alice@example.com"

# Subject contains word
notmuch search "subject:invoice"

# Date range (relative)
notmuch search "date:1month..today"

# Date range (absolute)
notmuch search "date:2026-01-01..2026-03-31"

# Boolean operators
notmuch search "from:alice AND subject:contract"
notmuch search "from:alice OR from:bob"
notmuch search "invoice NOT spam"

# Tags
notmuch search "tag:inbox AND tag:unread"

# Attachment filename
notmuch search "attachment:*.pdf"

# Thread search
notmuch search "thread:{thread-id}"

# Combine
notmuch search "from:billing@vendor.com subject:invoice date:2026.."
```

### notmuch Tags

notmuch uses tags for organization (equivalent to IMAP flags/folders):

```bash
# Tag messages
notmuch tag +inbox +unread -- "from:alice@example.com"

# Remove tag
notmuch tag -inbox -- "tag:inbox AND date:..1month"

# List all tags
notmuch search --output=tags '*'
```

### notmuch Incremental Indexing

```bash
# Index new messages (run after mbsync)
notmuch new

# Automate: add to mbsync post-sync hook or cron
# crontab: */15 * * * * mbsync -a && notmuch new --quiet
```

## mu Deep Dive

### Setup

```bash
# Install mu
brew install mu  # macOS
apt install maildir-utils  # Linux (Debian/Ubuntu)

# Initialize and index
mailbox-search-helper.sh setup --backend mu --maildir ~/Maildir

# Or manually:
mu init --maildir=~/Maildir
mu index
```

### mu Query Language

```bash
# From sender
mu find "from:alice@example.com"

# Subject
mu find "subject:invoice"

# Date range
mu find "date:20260101..20260401"

# MIME type (attachment search)
mu find "mime:application/pdf"
mu find "mime:application/vnd.openxmlformats-officedocument.wordprocessingml.document"

# Has attachment
mu find "flag:attach"

# Combine
mu find "from:billing@vendor.com subject:invoice date:20260101.."

# JSON output
mu find --format=json "subject:contract"
```

### mu Incremental Indexing

```bash
# Re-index after new messages arrive
mu index

# Automate with mbsync post-sync hook
```

## Attachment Content Search

### macOS Spotlight (Best Coverage)

Spotlight indexes attachment content natively. No extra configuration needed.

```bash
# Search PDF content
mailbox-search-helper.sh search-attachments "NDA agreement" --type pdf --backend spotlight

# Search all attachment types
mailbox-search-helper.sh search-attachments "quarterly revenue" --backend spotlight
```

Supported by Spotlight importers (built-in):
- PDF (text layer)
- Microsoft Word (.doc, .docx)
- Microsoft Excel (.xls, .xlsx)
- Microsoft PowerPoint (.ppt, .pptx)
- Plain text (.txt, .csv, .md)
- RTF

### notmuch (Filename Only)

notmuch indexes attachment filenames but not content. Use `attachment:` prefix:

```bash
# Find emails with PDF attachments matching filename
mailbox-search-helper.sh search-attachments "invoice" --type pdf --backend notmuch
# Equivalent to: notmuch search "invoice attachment:*.pdf"
```

For attachment content search with notmuch, extract attachments and use a separate full-text indexer (e.g., recoll, swish-e).

### mu (MIME Type Filter)

mu supports MIME type filtering for attachment search:

```bash
# Find emails with PDF attachments
mailbox-search-helper.sh search-attachments "contract" --type pdf --backend mu
# Equivalent to: mu find "contract mime:application/pdf"
```

## Integration with email-mailbox-helper.sh

The mailbox search helper complements `email-mailbox-helper.sh` (t1493):

- `email-mailbox-helper.sh search` — IMAP SEARCH on the server (live, no local index)
- `mailbox-search-helper.sh search` — OS-level indexed search (fast, offline, attachment content)

Use IMAP search when you need live server state. Use OS-level search for speed, attachment content, and offline access.

```bash
# IMAP search (server-side, live)
email-mailbox-helper.sh search myaccount --query "SUBJECT invoice SINCE 01-Jan-2026"

# OS-level search (indexed, fast, includes attachment content)
mailbox-search-helper.sh search "invoice Q1 2026" --backend spotlight
```

## Troubleshooting

### Spotlight Returns No Results

1. Check indexing is enabled: `mdutil -s /`
2. Verify Mail.app has downloaded messages locally (not IMAP-only)
3. Check message count: `mdfind "kMDItemContentType == 'com.apple.mail.emlx'" | wc -l`
4. Re-index if count is 0: `sudo mdutil -E /` (takes time)
5. For `.eml` files: verify they are in a Spotlight-indexed location (not excluded in Privacy settings)

### notmuch Returns No Results

1. Check database path: `notmuch config get database.path`
2. Verify maildir exists and has messages: `ls ~/Maildir/`
3. Re-index: `notmuch new`
4. Check message count: `notmuch count`
5. Test simple query: `notmuch search '*'`

### mu Returns No Results

1. Check mu database: `mu info`
2. Verify maildir: `ls ~/Maildir/`
3. Re-index: `mu index`
4. Test: `mu find '*'`

### Attachment Content Not Found

- **Spotlight**: ensure the file type has a Spotlight importer. Check: `mdimport -L` lists all importers.
- **notmuch**: attachment content is not indexed — use filename search only.
- **mu**: MIME type filter only — not full-text content search.

## Related

- `services/email/email-mailbox.md` — IMAP/JMAP mailbox operations, smart mailboxes, Sieve rules
- `scripts/email-mailbox-helper.sh` — IMAP/JMAP operations helper (t1493)
- `scripts/mailbox-search-helper.sh` — this helper
- `services/email/email-agent.md` — autonomous email communication

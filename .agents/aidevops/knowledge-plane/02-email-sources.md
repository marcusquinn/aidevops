# Knowledge Plane — Email Sources and Automation

Parent index: `../knowledge-plane.md`.

## Email Kind (`kind=email`) (t2854)

`.eml` and `.emlx` (Apple Mail) files are ingested as first-class `kind=email` sources.
When `knowledge-helper.sh add` receives an `.eml`/`.emlx` file, it delegates to
`email-ingest-helper.sh` which parses headers, body, and attachments into structured
sources.

### Email-Specific Meta Fields

Parent source (`kind=email`) `meta.json` extends the base schema with:

```json
{
  "kind": "email",
  "from": "sender@example.com",
  "to": "recipient@example.com",
  "cc": "cc@example.com",
  "bcc": "",
  "date": "Wed, 23 Apr 2026 10:00:00 +0000",
  "subject": "Email subject line",
  "message_id": "<unique-id@example.com>",
  "in_reply_to": "<parent-id@example.com>",
  "references": "<thread-id@example.com>",
  "body_text_sha": "sha256-of-text.txt",
  "body_html_sha": "sha256-of-body.html",
  "attachments": [
    {"source_id": "child-source-id", "filename": "report.pdf"}
  ]
}
```

Child source (`kind=attachment`) `meta.json` adds:

```json
{
  "kind": "attachment",
  "parent_source": "parent-email-source-id",
  "attachment_filename": "report.pdf",
  "content_type": "application/pdf"
}
```

### Source File Layout

```text
sources/<email-id>/
  meta.json          # kind=email, full email headers + attachment refs
  text.txt           # Plain-text body (or text extracted from HTML-only)
  body.html          # Sanitised HTML body (if present)
sources/<attachment-id>/
  meta.json          # kind=attachment, parent_source linkage
  report.pdf         # Original attachment file
```

### Body Sanitisation

Stored email bodies are sanitised on ingest for privacy and reproducibility:

- **Tracking pixels:** `<img src="https://...">` tags are replaced with
  `<!-- tracker stripped -->` comments.
- **UTM parameters:** `?utm_source=...&utm_medium=...` query strings are stripped
  from URLs in the HTML body.
- **Remote images:** all remote `<img>` sources are stripped (prevents phone-home
  on re-render).

Sanitisation is idempotent — re-ingesting the same `.eml` produces identical
`body.html` output.

### MIME Edge Cases

| Case | Handling |
|------|----------|
| `multipart/alternative` (text + html) | Both extracted; text preferred for `text.txt` |
| `multipart/related` (html + inline images) | Inline images treated as attachments |
| Apple Mail `.emlx` | Length-prefix header stripped before parsing |
| Quoted-printable encoding | Decoded by Python `email` stdlib |
| Base64-encoded bodies | Decoded by Python `email` stdlib |
| Non-UTF-8 charsets | Attempted UTF-8, fallback to latin-1 with warning |

### CLI

```bash
# Direct ingestion via email helper
email-ingest-helper.sh ingest /path/to/email.eml [--repo-path <path>] [--sensitivity <tier>]

# Auto-detected via knowledge add
knowledge-helper.sh add /path/to/email.eml
```

### Sensitivity Classification

Each source (parent email body + each child attachment) is independently classified
by the sensitivity detector (t2846). A benign email body at `tier:internal` can have
a contract attachment at `tier:privileged` — the child's tier is independent of the
parent's.


## IMAP Polling (t2855)

The pulse-driven `r044` routine polls configured IMAP mailboxes every 10 minutes,
drops new messages as `.eml` files into `_knowledge/inbox/`, and the existing
ingestion pipeline (t2854) picks them up from there.

### Setup

**1. Store the mailbox password in gopass:**

```bash
aidevops secret set email/personal-icloud/password
# or directly: gopass insert aidevops/email/personal-icloud/password
```

**2. Register the mailbox interactively:**

```bash
aidevops email mailbox add
```

This prompts for provider (auto-fills IMAP host/port from `email-providers.json.txt`),
username, gopass path, and which folders to poll. It tests the connection before
saving.

**3. Verify the configuration:**

```bash
aidevops email mailbox list       # shows all registered mailboxes + state
aidevops email mailbox test <id>  # dry-run: connect + fetch 1 message, no writes
```

**4. Enable the polling routine:**

The `r044` entry in `TODO.md` is enabled by default (`[x]`). The pulse picks it
up and runs `scripts/email-poll-helper.sh tick` every 10 minutes.

To disable: change `[x] r044` to `[ ] r044` in `TODO.md`.

### Manual Operations

```bash
# Poll all mailboxes immediately (same as the r044 routine)
~/.aidevops/agents/scripts/email-poll-helper.sh tick

# Back-fill historical messages from 2026-01-01 (rate-limited to 100 msg/min)
~/.aidevops/agents/scripts/email-poll-helper.sh backfill <mailbox-id>     --since 2026-01-01     --rate-limit 100

# Show all mailboxes and their last-polled timestamps
~/.aidevops/agents/scripts/email-poll-helper.sh list
```

### mailboxes.json Schema

```json
{
  "mailboxes": [
    {
      "id": "personal-icloud",
      "provider": "icloud",
      "host": "imap.mail.me.com",
      "port": 993,
      "user": "you@icloud.com",
      "password_ref": "gopass:aidevops/email/personal-icloud/password",
      "folders": ["INBOX", "Cases/2026"],
      "since": "2026-01-01"
    }
  ]
}
```

Field reference:

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier used in state keys and .eml filenames |
| `provider` | string | Provider slug (matched against `email-providers.json.txt` for host defaults) |
| `host` | string | IMAP server hostname |
| `port` | integer | IMAP port — use 993 (TLS/SSL). Port 143/STARTTLS is not supported; the implementation uses `IMAP4_SSL` exclusively. |
| `user` | string | Login username / email address |
| `password_ref` | string | `gopass:<path>` or environment variable name |
| `folders` | array | IMAP folders to poll — each tracked independently |
| `since` | string | ISO date — only used on first backfill, not by routine ticks |

### Credential Resolution

`password_ref` supports two forms:


## Email Thread Reconstruction (t2856)

Email sources with `"kind": "email"` support JWZ-style thread reconstruction.
Thread indexes live at `_knowledge/index/email-threads/<thread-id>.json`:

```json
{
  "thread_id": "<msg-001@example.com>",
  "root_subject": "Project kickoff",
  "participants": ["alice@example.com", "bob@example.com"],
  "sources": [
    {"source_id": "src-001", "message_id": "<msg-001@example.com>", "date": "2026-01-10T09:00:00Z", "from": "alice@example.com"},
    {"source_id": "src-002", "message_id": "<msg-002@example.com>", "date": "2026-01-10T10:00:00Z", "from": "bob@example.com"}
  ]
}
```

**Threading algorithm (JWZ):**

1. Parent-link via `in_reply_to` — if the referenced message_id is in the corpus
2. Fall back to last entry in `references` header
3. Subject-merge orphans: emails sharing a normalised subject (strip Re:/Fwd:, lowercase) but lacking In-Reply-To are grouped under the earliest message as root

**Incremental:** re-threads only when source meta.json files change (mtime comparison). Use `--force` to rebuild unconditionally.

**Email meta.json fields used:** `id`, `kind`, `message_id`, `in_reply_to`, `references`, `subject`, `from`, `date`/`ingested_at`.

```bash
aidevops email build   [knowledge-root] [--force]        # Rebuild thread index
aidevops email thread  <message-id> [knowledge-root]     # Look up thread by message-id
```

Helper: `.agents/scripts/email-thread-helper.sh`.
Python module: `.agents/scripts/email_thread.py`.


## Email Filter → Case-Attach (t2856)

Sieve-style rules in `_config/email-filters.json` auto-attach matched email
sources to cases when the filter tick runs (routine `r045`, every 15 min).

**Filter config:** `<repo>/_config/email-filters.json` (template at `.agents/templates/email-filters-config.json`):

```json
{
  "rules": [
    {
      "name": "Dispute counsel correspondence",
      "match": {
        "from_contains": "counsel@example.com",
        "subject_contains_any": ["Re: Dispute"]
      },
      "actions": [
        { "attach_to_case": "case-2026-0001-dispute-acme", "role": "evidence" },
        { "set_sensitivity": "privileged" }
      ]
    }
  ]
}
```

**Match predicates (AND semantics — all must match):**

| Predicate | Type | Description |
|-----------|------|-------------|
| `from_contains` | string | Partial match on From/Sender (case-insensitive) |
| `from_equals` | string | Exact match on From/Sender |
| `subject_contains_any` | string[] | Any element present in Subject (case-insensitive) |
| `subject_matches_regex` | string | Python regex matched against Subject |
| `body_contains` | string | Partial match on body_preview/body |
| `has_attachment_kind` | string | Attachment kind present in `attachments[]` |

**Actions:**

| Action | Description |
|--------|-------------|
| `attach_to_case` + `role` | Calls `case-helper.sh attach <case-id> <source-id> --role <role>` |
| `set_sensitivity` | Updates `sensitivity` field in meta.json |

**Filter state:** `_knowledge/.email-filter-state.json` — last-processed source ID, prevents double-processing.

**Audit log:** `_cases/<case-id>/comms/email-attach.jsonl` — one line per attachment action.

```bash
aidevops email filter tick   [knowledge-root]             # Run filter pass (called by r045)
aidevops email filter list   [knowledge-root]             # List rules with match summaries
aidevops email filter add    [knowledge-root]             # Interactive rule builder
aidevops email filter test   <rule-name> [knowledge-root] # Dry-run against last 50 sources
```

Helper: `.agents/scripts/email-filter-helper.sh`.

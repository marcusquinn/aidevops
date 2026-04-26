# Knowledge Plane — Directory Contract

The knowledge plane is an opt-in file staging area for AI-assisted ingestion of
external documents, data exports, and reference material into aidevops-managed
repos. Each repo can independently enable or disable the plane.

## Modes (`repos.json` field: `knowledge`)

| Value | Description |
|-------|-------------|
| `"off"` | No knowledge plane (default; backwards-compatible) |
| `"repo"` | `_knowledge/` tree inside the repo (versioned with the project) |
| `"personal"` | Shared plane at `~/.aidevops/.agent-workspace/knowledge/` (cross-repo) |

`"off"` is the default so all existing repos are unaffected until explicitly enabled.

`"personal"` mode is useful when knowledge doesn't belong to any single repo yet
(early-stage work, cross-project research, or when no target repo exists).

## Directory Layout

```
_knowledge/          ← root (or ~/.aidevops/.agent-workspace/knowledge/)
  inbox/             ← raw drops — gitignored, pre-review zone
  staging/           ← curated before commit — gitignored
  sources/           ← versioned originals (files ≤30MB)
  index/             ← generated search index — gitignored by default
  collections/       ← named curated subsets — versioned
  _config/
    knowledge.json   ← defaults (sensitivity, trust, ingest policy)
```

**Provision:** `aidevops knowledge init repo` or `aidevops knowledge init personal`.
**Repair:** `aidevops knowledge provision` is idempotent — safe to re-run.

## .gitignore Rules

The provisioner writes two sets of `.gitignore` rules:

1. **`_knowledge/.gitignore`** — ignores `inbox/`, `staging/`, and `index/` within the
   knowledge root. `sources/` and `collections/` are intentionally NOT ignored —
   versioned originals belong in git.

2. **Repo root `.gitignore`** — appends a `# knowledge-plane-rules` block with
   `_knowledge/inbox/`, `_knowledge/staging/`, `_knowledge/index/` for belt-and-
   suspenders coverage.

## Source `meta.json` Schema

Each ingested source should have a `meta.json` alongside its content in `sources/`:

```json
{
  "version": 1,
  "id": "unique-kebab-id",
  "kind": "document|dataset|export|reference",
  "source_uri": "https://original.url.or/local/path",
  "sha256": "hex-hash-of-original-file",
  "ingested_at": "2026-04-25T00:00:00Z",
  "ingested_by": "agent-or-username",
  "sensitivity": "public|internal|confidential|restricted",
  "trust": "unverified|reviewed|trusted|authoritative",
  "blob_path": null,
  "size_bytes": 12345
}
```

Fields: `id` (unique within repo), `kind` (broad category), `source_uri` (original
location for re-verification), `sha256` (integrity check), `sensitivity`/`trust` (policy
enforcement), `blob_path` (set when file ≥30MB — see below), `size_bytes` (raw byte count).

## 30MB Blob Threshold

Files ≥30MB are NOT stored in-repo. Instead:

1. The original is moved to `~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/<source-id>/`.
2. `meta.json` sets `"blob_path": "~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/<source-id>/<filename>"`.
3. Only the `meta.json` is committed.

**Rationale:** git performance degrades with large binaries; LFS is optional and
complicates cloning; the agent-workspace path is local and survives repo clones.
30MB is the threshold where git's pack performance starts to noticeably degrade
for typical document files (PDFs, exports, dumps).

## `_config/knowledge.json` Defaults

Written at provision time from `.agents/templates/knowledge-config.json`:

```json
{
  "version": 1,
  "sensitivity_default": "internal",
  "trust_default": "unverified",
  "blob_threshold_bytes": 31457280,
  "trust_ladder": ["unverified", "reviewed", "trusted", "authoritative"],
  "sensitivity_levels": ["public", "internal", "confidential", "restricted"],
  "ingest_policy": {
    "auto_sha256": true,
    "require_meta": true
  }
}
```

Override per-repo by editing `_knowledge/_config/knowledge.json` after provisioning.

## Personal vs Repo Plane

| Aspect | `repo` | `personal` |
|--------|--------|------------|
| Location | `<repo>/_knowledge/` | `~/.aidevops/.agent-workspace/knowledge/` |
| Versioned | Yes (with repo) | No (local only) |
| Scope | Single repo | All repos on this machine |
| Use case | Project-specific docs | Early-stage, cross-project |
| Gitignore | Patched in repo | Not applicable |

## CLI

```bash
aidevops knowledge init repo           # Provision _knowledge/ in current repo
aidevops knowledge init personal       # Provision at ~/.aidevops/.agent-workspace/knowledge/
aidevops knowledge init off            # Disable knowledge plane for current repo
aidevops knowledge status              # Show provisioning state + item counts
aidevops knowledge provision [path]    # Re-provision / repair (idempotent)

# Ingest a file (auto-classifies sensitivity)
knowledge-helper.sh add path/to/file.pdf

# Ingest with explicit sensitivity override
knowledge-helper.sh add path/to/file.pdf --sensitivity privileged

# Manual sensitivity correction after ingestion
knowledge-helper.sh sensitivity override <source-id> privileged --reason "Legal advice per review"

# Show current tier + audit trail for a source
knowledge-helper.sh sensitivity show <source-id>
```

The helper: `.agents/scripts/knowledge-helper.sh`.

---

## Sensitivity Classification (t2846)

Every ingested source is automatically stamped with a sensitivity tier. Detection runs
entirely offline — no cloud calls, no network.

### Tiers

| Tier | Redact | LLM Policy | Retention | Description |
|------|--------|------------|-----------|-------------|
| `public` | No | Any | 10 yr | Public-facing content |
| `internal` | No | Cloud OK | 7 yr | Internal business docs |
| `pii` | Yes | Local or redacted cloud | 7 yr | Personal data |
| `sensitive` | Yes | Local only | 7 yr | Board, strategy, HR |
| `privileged` | Yes | Local hard-fail | 10 yr | Attorney-client, regulatory |

Tier precedence (highest wins): `privileged > sensitive > pii > internal > public`

### Detection Pipeline

1. **Regex/pattern**: NI numbers, IBAN, payment cards, email addresses, postcodes → `pii`
2. **Path heuristics**: `legal/`, `privileged/`, `board-minutes/`, `strategy/` → tier per config
3. **Maintainer override**: `--sensitivity <tier>` on `knowledge add` or `sensitivity override` subcommand
4. **Precautionary upgrade** (P0.5c pending): ambiguous content defaults to `internal` until
   local-LLM (Ollama, P0.5c) ships. After P0.5c, routes via `llm-routing-helper.sh`.

### Configuration

Default patterns and heuristics: `.agents/templates/sensitivity-config.json`

Deployed at: `_knowledge/_config/sensitivity.json`

To customise per-repo: edit `_knowledge/_config/sensitivity.json` after provisioning.

### Audit Log

Every classification is recorded at `_knowledge/index/sensitivity-audit.log` (JSONL):

```json
{"ts":"2026-04-27T10:00:00Z","source_id":"my-doc","tier":"pii","evidence":"regex:uk_ni","actor":"sensitivity-detector"}
```

### Override CLI

```bash
# Manual correction with audit trail
knowledge-helper.sh sensitivity override <source-id> internal --reason "False positive NI match"

# View current tier + recent audit entries
knowledge-helper.sh sensitivity show <source-id>
```

### meta.json Fields

| Field | Description |
|-------|-------------|
| `sensitivity` | Current tier (`public`\|`internal`\|`pii`\|`sensitive`\|`privileged`) |
| `sensitivity_override` | Manually set tier (detector respects this on re-classify) |
| `sensitivity_override_reason` | Free-text reason for the override |

---

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
~/.aidevops/agents/scripts/email-poll-helper.sh backfill <mailbox-id> \
    --since 2026-01-01 \
    --rate-limit 100

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
| `port` | integer | IMAP port (993 = TLS, 143 = STARTTLS) |
| `user` | string | Login username / email address |
| `password_ref` | string | `gopass:<path>` or environment variable name |
| `folders` | array | IMAP folders to poll — each tracked independently |
| `since` | string | ISO date — only used on first backfill, not by routine ticks |

### Credential Resolution

`password_ref` supports two forms:

- `gopass:aidevops/email/<id>/password` → calls `gopass show -o <path>` silently
- `MY_ENV_VAR` → reads from environment variable `MY_ENV_VAR`

The resolved password is **never** logged or written to any file.

### State File

`_knowledge/.imap-state.json` persists the last-seen UID per mailbox+folder:

```json
{
  "personal-icloud/INBOX": {
    "last_uid_seen": 3421,
    "last_polled_at": "2026-04-26T21:00:00+00:00"
  },
  "personal-icloud": {
    "last_polled_at": "2026-04-26T21:00:00+00:00"
  }
}
```

Each tick fetches only UIDs strictly greater than `last_uid_seen`, guaranteeing
no duplicate `.eml` files across restarts or pulse restarts.

### Error Handling

- **Wrong password / credential not found** → `status: credential_error` in tick
  output; `last_error` recorded in state; pulse continues with next mailbox.
- **Connection refused / DNS failure** → `status: connection_error` in tick output;
  `last_error` recorded; pulse continues.
- **Partial folder error** → `status: partial_error`; successfully-polled folders
  update state; failed folder logged; pulse continues.
- **Lock contention** → if a previous tick is still running, the new tick exits
  cleanly (no second poll). Lock is a directory mutex in
  `~/.aidevops/.agent-workspace/locks/email-poll.lock`.

### .eml Filename Convention

```
_knowledge/inbox/email-<mailbox-id>-<uid>.eml
```

Example: `email-personal-icloud-3421.eml`

Hyphens in mailbox IDs are preserved; other non-alphanumeric characters are
replaced with underscores. UIDs are stable per IMAP server (UIDPLUS-compatible).

### Backfill

First-time setup of a mailbox with existing messages:

```bash
~/.aidevops/agents/scripts/email-poll-helper.sh backfill personal-icloud \
    --since 2026-01-01 \
    --rate-limit 100
```

- `--since` accepts ISO date `YYYY-MM-DD`.
- `--rate-limit` defaults to 100 messages/minute. Set to 0 for no throttle
  (not recommended for large mailboxes — risks IMAP server rate limits).
- Backfill does **not** update the high-watermark UID; it is additive. After
  backfill, the routine tick resumes from where it left off.

### Removing a Mailbox

```bash
aidevops email mailbox remove <id>
```

This removes the entry from `mailboxes.json`. The state entry at
`_knowledge/.imap-state.json` and any already-fetched `.eml` files are preserved.

### Dependencies

- Python 3 (stdlib only: `imaplib`, `email`, `json`, `re`, `subprocess`, `pathlib`)
- gopass (for credential resolution when using `gopass:` references)
- `shared-constants.sh` (sourced by `email-poll-helper.sh`)

### Provider IMAP Hosts

See `.agents/configs/email-providers.json.txt` for a full list of supported
providers with verified IMAP host/port pairs. The `aidevops email mailbox add`
command auto-fills these when you specify a known provider slug.

Common providers:

| Provider | Host | Port |
|----------|------|------|
| iCloud | imap.mail.me.com | 993 |
| Gmail | imap.gmail.com | 993 |
| Fastmail | imap.fastmail.com | 993 |
| Cloudron | my.yourdomain.com | 993 |
| Outlook.com | outlook.office365.com | 993 |

### Routine r044

The routine entry in `TODO.md`:

```
- [x] r044 IMAP mailbox polling — fetch new emails to _knowledge/inbox/ repeat:cron(*/10 * * * *) ~1m run:scripts/email-poll-helper.sh tick
```

- `repeat:cron(*/10 * * * *)` — runs every 10 minutes
- `run:scripts/email-poll-helper.sh tick` — the pulse executes this script
- Lock-protected — only one poll runs per cycle
- Errors are fail-open: connection failures or missing credentials are logged
  but do not crash the pulse

To disable: change `[x]` to `[ ]` in `TODO.md` and commit.

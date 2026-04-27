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

## Structured Field Extraction / Enrichment (t2849)

After a source is promoted to `sources/`, the enrichment pipeline extracts structured
fields from the OCR text and writes `_knowledge/sources/<id>/extracted.json` with
per-field provenance.

### What Enrichment Produces

```json
{
  "version": 1,
  "source_id": "my-invoice",
  "kind": "invoice",
  "schema_version": 1,
  "schema_hash": "a3f2c1d4e5b6",
  "enriched_at": "2026-04-27T10:00:00Z",
  "fields": {
    "invoice_number": { "value": "INV-2026-001", "confidence": "high", "source": "regex", "evidence_excerpt": "Invoice Number: INV-2026-001", "page": null },
    "supplier_name":  { "value": "Acme Corp Ltd", "confidence": "high", "source": "llm",   "evidence_excerpt": "Supplier: Acme Corp Ltd", "page": null }
  }
}
```

### Schemas

Seven extraction schemas live in `.agents/tools/document/extraction-schemas/`:

| Kind | Schema | Sensitivity |
|------|--------|-------------|
| `invoice` | `invoice.json` | `internal` |
| `contract` | `contract.json` | `internal`/`sensitive` |
| `bank_statement` | `bank_statement.json` | `pii` |
| `financial_statement` | `financial_statement.json` | `internal`/`sensitive` |
| `payment_receipt` | `payment_receipt.json` | `pii` |
| `email` | `email.json` | `pii` |
| `generic` | `generic.json` | `internal` (fallback) |

Each field declares `extractor: "regex"` (fast, deterministic) or `extractor: "llm"`
(flexible). LLM fields route through `llm-routing-helper.sh` with the source's
`sensitivity` tier — PII documents stay local.

### CLI

```bash
# Enrich a specific source (kind from meta.json)
aidevops knowledge enrich <source-id>

# Override kind when meta.json has wrong value
document-enrich-helper.sh enrich <source-id> --kind contract

# Batch: enrich all sources without extracted.json (same as r041)
document-enrich-helper.sh tick

# Dry-run — show what would be extracted without writing
document-enrich-helper.sh enrich <source-id> --dry-run

# Force re-extract even if extracted.json exists
document-enrich-helper.sh enrich <source-id> --force-refresh

# Show enrichment status across sources
document-enrich-helper.sh status
```

### Idempotency

Tracks a 12-char schema hash in `extracted.json::schema_hash`. Same hash → skip
(no LLM calls, no file write). Schema changed → re-extract. `--force-refresh` → always.

### Routine r041

```
- [x] r041 Knowledge enrichment — extract structured fields from freshly-promoted sources repeat:cron(*/30 * * * *) ~2m run:scripts/document-enrich-helper.sh tick
```

### Schema Authoring

Create `.agents/tools/document/extraction-schemas/<kind>.json` with the format shown
in `10-classification.md §Extraction Schemas`. The helper auto-discovers schemas by
filename — no registration step needed.

---

## Corpus Index (t2850)

The pulse-driven `r042` routine runs hourly, incrementally rebuilds per-source
PageIndex trees and aggregates them into a corpus-wide tree for vectorless RAG.

### How It Works

1. **Per-source tree** (`build-source <id>`): reads `_knowledge/sources/<id>/text.txt`,
   calls `pageindex-generator.py` with the source's sensitivity-based LLM tier, writes
   `_knowledge/sources/<id>/tree.json`.
2. **Corpus aggregation** (`build`): groups source trees by kind (invoices, contracts, …),
   builds a meta-tree with root `corpus` and children grouped by kind, writes
   `_knowledge/index/tree.json`.
3. **Incremental rebuild**: hashes source IDs + tree.json mtimes; skips if hash matches
   `_knowledge/index/.tree-hash`. Only newly-added or changed sources are rebuilt.
4. **LLM routing**: each source's sensitivity field maps to an `llm-routing-helper.sh`
   tier (`public/internal/sensitive/privileged`). Routing decisions are audited to
   `_knowledge/index/llm-audit.log` (JSONL, hashed — no raw content).

### Query

```bash
# Query via CLI
aidevops knowledge search "all invoices over £5k"

# Direct invocation
knowledge-index-helper.sh query "all invoices over £5k"
```

Returns JSON: `{"matches": [{"source_id": "…", "score": 4, "anchor": "…", "excerpt": "…"}]}`

`aidevops knowledge search` auto-routes to `knowledge-index-helper.sh query` when the
corpus tree exists; falls back to grep over `text.txt` files otherwise.

### Routine r042

```
- [x] r042 Knowledge index build — incremental PageIndex tree across corpus repeat:cron(*/60 * * * *) ~2m run:scripts/knowledge-index-helper.sh build
```

To disable: change `[x]` to `[ ]` in `TODO.md` and commit.

### Helper CLI

```bash
# Build corpus index (same as r042 routine)
~/.aidevops/agents/scripts/knowledge-index-helper.sh build

# Build tree for one source
~/.aidevops/agents/scripts/knowledge-index-helper.sh build-source <source-id>

# Query the corpus
~/.aidevops/agents/scripts/knowledge-index-helper.sh query "invoice 2026"

# Show index state
~/.aidevops/agents/scripts/knowledge-index-helper.sh status
```

### Files

| File | Description |
|------|-------------|
| `.agents/scripts/knowledge-index-helper.sh` | Shell orchestrator — build, query, status |
| `.agents/scripts/knowledge_index_helpers.py` | Python helper — aggregate + keyword-score query |
| `_knowledge/sources/<id>/tree.json` | Per-source PageIndex tree |
| `_knowledge/index/tree.json` | Corpus meta-tree (aggregated) |
| `_knowledge/index/.tree-hash` | Incremental rebuild cache |
| `_knowledge/index/llm-audit.log` | LLM routing audit (JSONL) |

---

## Review Gate (t2845)

The pulse-driven `r040` routine runs every 15 minutes, scans
`_knowledge/inbox/` for pending sources, and classifies them using the trust
ladder defined in `_knowledge/_config/knowledge.json`.

### Trust Ladder

Three trust classes determine what happens to each inbox item:

| Class | Trigger | Action |
|-------|---------|--------|
| `auto_promote` | `meta.json` `trust: "trusted"\|"authoritative"`, OR `ingested_by` matches a configured bot/email, OR `source_uri` starts with a trusted path | Direct promotion: inbox → staging → sources + audit entry |
| `review_gate` | `ingested_by` matches `trust.review_gate.from_emails` | Staged + `kind:knowledge-review` issue filed with `auto-dispatch` (light review, worker-handled) |
| `untrusted` | Default (`"*"`) | Staged + `kind:knowledge-review` issue filed with `needs-maintainer-review` (requires crypto-approval) |

### Trust Config

Defined in `_knowledge/_config/knowledge.json` (written at provision time from
`.agents/templates/knowledge-config.json`):

```json
{
  "trust": {
    "auto_promote": {
      "from_paths": ["~/Drops/maintainer-knowledge/"],
      "from_emails": ["you@yourdomain.com"],
      "from_bots":   ["my-internal-bot"]
    },
    "review_gate": {
      "from_emails": ["partner@example.com"]
    },
    "untrusted": "*"
  }
}
```

Override per-repo after provisioning: edit `_knowledge/_config/knowledge.json`
directly. The config is versioned in `sources/` — changes are tracked in git.

### NMR Issues

Untrusted and review_gate sources produce `kind:knowledge-review` GitHub
issues. Each issue body includes:

- Source ID, kind, SHA256, size, ingested_by, sensitivity
- Trust class and review instructions
- Text preview (first 500 chars) of the source content

**Untrusted**: issues carry `needs-maintainer-review`. Approve with:

```bash
sudo aidevops approve issue <N>
```

This triggers `knowledge-review-helper.sh promote <source-id>`, which moves
the source from `_knowledge/staging/` to `_knowledge/sources/`, updates
`meta.json` with `state: "promoted"`, and closes the issue.

**Review-gate**: issues carry `auto-dispatch`. A worker reviews and can promote
by calling the same `promote` subcommand.

### Audit Log

Every action is appended to `_knowledge/index/audit.log` (JSONL):

```json
{"ts":"2026-04-27T00:00:00Z","action":"auto_promoted","source_id":"my-doc","actor":"tick","extra":"actor:tick"}
{"ts":"2026-04-27T00:01:00Z","action":"nmr_filed","source_id":"ext-doc","actor":"tick","extra":"issue:https://github.com/… trust_class:untrusted"}
{"ts":"2026-04-27T12:00:00Z","action":"promoted","source_id":"ext-doc","actor":"maintainer","extra":"actor:maintainer path:approve_hook"}
```

`_knowledge/index/` is gitignored — the audit log is local only.

### Routine r040

```
- [x] r040 Knowledge review gate — classify inbox items by trust, auto-promote or NMR-file repeat:cron(*/15 * * * *) ~1m run:scripts/knowledge-review-helper.sh tick
```

To disable: change `[x]` to `[ ]` in `TODO.md` and commit.

### Helper CLI

```bash
# Manual tick (same as r040 routine)
~/.aidevops/agents/scripts/knowledge-review-helper.sh tick

# Explicit promotion (called automatically by approve hook)
~/.aidevops/agents/scripts/knowledge-review-helper.sh promote <source-id>

# Manual audit entry
~/.aidevops/agents/scripts/knowledge-review-helper.sh audit-log <action> <source-id> [extra]
```

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

## LLM Routing

All LLM calls in the framework are centralised behind `llm-routing-helper.sh`. Direct invocations of `claude`, `ollama`, or any other LLM CLI are prohibited in new helpers — route through this layer instead.

### Sensitivity Tiers

Every LLM call is assigned a sensitivity tier that controls which providers are allowed:

| Tier | Allowed providers | Default | Notes |
|------|-------------------|---------|-------|
| `public` | any | anthropic | No restrictions |
| `internal` | cloud or local | anthropic | Normal framework data |
| `pii` | local preferred; cloud with redaction | ollama | Redaction applied before cloud calls |
| `sensitive` | local only | ollama | No cloud fallback |
| `privileged` | local only | ollama | Hard-fail if Ollama is not running |

**Hard-fail rule:** when `tier=privileged` and no local provider is available, `llm-routing-helper.sh` exits 1 with "no compliant provider for tier=privileged". There is no silent fallback to cloud.

### Routing Decision Tree

```
route --tier <t> --prompt-file <p>
  │
  ├─ tier = public/internal?
  │     └─ use default_provider from config (anthropic)
  │
  ├─ tier = pii?
  │     ├─ Ollama running? → use Ollama (no redaction needed)
  │     └─ cloud provider? → call redaction-helper.sh first, then cloud
  │
  ├─ tier = sensitive?
  │     ├─ Ollama running? → use Ollama
  │     └─ Ollama down? → exit 1 (no cloud fallback)
  │
  └─ tier = privileged?
        ├─ Ollama running? → use Ollama
        └─ Ollama down? → EXIT 1 (hard-fail, policy enforced)
```

### Audit Log

Every LLM call appends a JSONL record to `_knowledge/index/llm-audit.log`:

```json
{
  "timestamp": "2026-04-27T12:00:00Z",
  "tier": "public",
  "task": "summarise",
  "provider": "anthropic",
  "redaction_applied": false,
  "prompt_sha256": "<sha256 of prompt — not raw content>",
  "response_sha256": "<sha256 of response — not raw content>",
  "tokens": 512,
  "cost": "0"
}
```

Raw prompts and responses are **never** stored in the audit log. Only SHA-256 hashes are recorded, providing provenance ("this call happened") without leaking content.

### Cost Tracking

Per-day per-provider costs are accumulated at `~/.aidevops/.agent-workspace/llm-costs.json`:

```bash
llm-routing-helper.sh costs --since 2026-04-01
llm-routing-helper.sh costs --provider ollama
```

### Configuration

Policy lives in `_config/llm-routing.json` (copy from `.agents/templates/llm-routing-config.json` on init). Key fields:

- `tiers.<name>.hard_fail_if_unavailable` — if true, exit 1 instead of falling back
- `tiers.<name>.redaction_required_for_cloud` — if true, call `redaction-helper.sh` before any cloud call
- `providers.<name>.kind` — `"local"` or `"cloud"`

### Redaction

`redaction-helper.sh redact <input> <output>` is called automatically for `pii` tier cloud calls. The MVP implementation is a pass-through stub — it copies the file unchanged and logs a warning. Real PII entity recognition is tracked as a post-MVP TODO in `redaction-helper.sh`.

### Usage

```bash
# Public tier — uses anthropic by default
llm-routing-helper.sh route --tier public --task summarise \
    --prompt-file /tmp/prompt.txt

# Privileged tier — uses Ollama; fails if not running
llm-routing-helper.sh route --tier privileged --task draft \
    --prompt-file /tmp/prompt.txt --max-tokens 4096

# Dry-run (no real LLM call — useful in tests)
LLM_ROUTING_DRY_RUN=1 llm-routing-helper.sh route \
    --tier pii --task classify --prompt-file /tmp/data.txt

# Check provider availability
llm-routing-helper.sh status
```

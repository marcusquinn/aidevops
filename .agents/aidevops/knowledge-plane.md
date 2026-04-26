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
```

The helper: `.agents/scripts/knowledge-helper.sh`.

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

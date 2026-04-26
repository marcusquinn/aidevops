# Knowledge Plane — Directory Contract

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

The knowledge plane is an opt-in, structured directory layout for ingesting,
staging, and versioning external knowledge sources into an aidevops-managed
repository. It is gated by the `knowledge` field in `repos.json`.

## Opt-in Modes

Set via `repos.json` or `aidevops knowledge init`:

| Value | Meaning |
|-------|---------|
| `"off"` | Disabled (default — existing repos unaffected) |
| `"repo"` | `_knowledge/` tree lives inside the repo |
| `"personal"` | Tree lives at `~/.aidevops/.agent-workspace/knowledge/` |

**`repo` mode** is for knowledge tightly coupled to a single repository (e.g.
API specs, domain glossaries, project-specific research).

**`personal` mode** is for knowledge that spans repos, predates repo creation,
or should not be committed to any single project (e.g. cross-project notes,
personal reference material, early-stage research not yet scoped to a repo).

## Directory Layout

```text
_knowledge/
├── inbox/         # Raw drops — pre-review, gitignored
├── staging/       # Curated before commit — gitignored
├── sources/       # Versioned originals (≤30MB) — committed
├── index/         # Generated search artifacts — gitignored by default
├── collections/   # Named curated subsets — committed
└── _config/
    └── knowledge.json   # Sensitivity policy, trust ladder, ingest settings
```

### Personal plane (same structure, different base):

```text
~/.aidevops/.agent-workspace/knowledge/
└── _knowledge/   (same subdirs as above)
```

## Directory Semantics

### `inbox/`

Raw, unreviewed drops. Files land here first. Gitignored so that accidental
adds of large or sensitive files never touch the index. Agents may scan inbox/
to propose staging or rejection. Nothing in inbox/ is trusted by default.

### `staging/`

Files that have been reviewed or curated but not yet committed. Gitignored.
This zone gives the maintainer one final look before the content enters the
versioned `sources/` tree. Typical flow: `inbox/ → staging/ → sources/`.

### `sources/`

Versioned originals. Files here are committed and subject to normal git history.
**Size threshold:** files ≥ 30MB must NOT be stored in `sources/` — instead,
store them at `~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/<source-id>/`
and record a pointer in `meta.json` (see below). The 30MB threshold keeps clone
times reasonable and avoids git LFS complexity for typical knowledge sources
(PDFs, markdown, text, code snippets).

### `index/`

Generated search artifacts (e.g. embeddings, BM25 term lists, chunk manifests).
Gitignored by default because they can be regenerated from `sources/`. Remove
from `.gitignore` if your workflow versions the index (e.g. to share pre-built
embeddings with teammates without requiring local reindex).

### `collections/`

Named, curated subsets of knowledge. A collection is a directory inside
`collections/` with its own README or manifest. Committed. Examples:
`collections/onboarding/`, `collections/api-reference/`, `collections/faq/`.

### `_config/`

Configuration committed with the repo. `knowledge.json` defines defaults for
sensitivity policy, trust ladder, and ingest settings. See schema below.

## `meta.json` Schema

Every file added to `sources/` SHOULD have a companion `<filename>.meta.json`
sidecar (or a single `meta.json` per directory listing all sources). Required
fields:

```json
{
  "version": 1,
  "id": "<uuid-or-slug>",
  "kind": "pdf|markdown|html|code|dataset|other",
  "source_uri": "https://...",
  "sha256": "<hex>",
  "ingested_at": "2026-04-25T10:00:00Z",
  "ingested_by": "claude-sonnet-4-6",
  "sensitivity": "public|internal|confidential|restricted",
  "trust": "unverified|reviewed|trusted|authoritative",
  "size_bytes": 12345,
  "blob_path": null
}
```

For files exceeding the 30MB threshold, `blob_path` holds the absolute path
to the external blob location and `sources/` contains only the `meta.json`
pointer (no binary):

```json
{
  "blob_path": "~/.aidevops/.agent-workspace/knowledge-blobs/myrepo/abc123/"
}
```

### `version` key

The `version` field is present for forward-compatibility. Always write `1`.
Future schema revisions increment this value so readers can adapt.

## `.gitignore` Rules

`knowledge-helper.sh provision` writes a `.gitignore` inside `_knowledge/`
and appends a fenced block to the repo root `.gitignore`:

```gitignore
# knowledge-plane-rules
_knowledge/inbox/
_knowledge/staging/
_knowledge/index/
```

`sources/` is intentionally NOT ignored. Raw-drop safety is handled by
`inbox/`; the gitignore block is belt-and-suspenders for direct file copies.

## Provisioning

### CLI

```bash
# Set mode and provision in one step
aidevops knowledge init repo            # current directory
aidevops knowledge init personal        # personal plane
aidevops knowledge init off             # disable

# Re-provision after directories were deleted (idempotent)
aidevops knowledge init repo /path/to/repo

# Status check
aidevops knowledge status
```

### Automatic (setup.sh)

`setup.sh` calls `knowledge-helper.sh provision` for every repo in
`repos.json` where `knowledge != "off"` during `aidevops update`. The
call is idempotent — existing directories and configs are not overwritten.

### Programmatic

```bash
knowledge-helper.sh provision /path/to/repo
```

Exit 0 on success or "already provisioned". Exit 1 on error.

## Sensitivity and Trust

The `_config/knowledge.json` file defines organisational defaults:

```json
{
  "sensitivity_default": "internal",
  "trust_default":       "unverified",
  "trust_ladder":        ["unverified", "reviewed", "trusted", "authoritative"],
  "sensitivity_levels":  ["public", "internal", "confidential", "restricted"]
}
```

These are defaults for the `meta.json` sidecar fields. Override per-file in
the sidecar. Sensitivity `"restricted"` means the file MUST NOT leave the
local machine; never commit restricted files to a public or shared repo.

## Personal vs Repo Plane

| Dimension | `repo` | `personal` |
|-----------|--------|------------|
| Location | `<repo>/_knowledge/` | `~/.aidevops/.agent-workspace/knowledge/_knowledge/` |
| Versioned by | git (per-repo) | not versioned (local only) |
| Access scope | all contributors to the repo | local machine only |
| Use case | project-specific knowledge | cross-repo or early-stage research |
| `aidevops update` provisions? | yes | yes |

## Reference

- Provisioning helper: `.agents/scripts/knowledge-helper.sh`
- Default config template: `.agents/templates/knowledge-config.json`
- Gitignore template: `.agents/templates/knowledge-gitignore.txt`
- Schema in `repos.json`: see `reference/repos-json-fields.md` field `knowledge`
- Parent task: t2840 / GH#20892

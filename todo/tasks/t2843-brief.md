---
mode: subagent
---

# t2843: knowledge CLI surface (add/list/search) + platform abstraction

## Pre-flight

- [x] Memory recall: `cli platform abstraction gh github gitea` → no relevant lessons; gh wrappers exist at `shared-gh-wrappers.sh`
- [x] Discovery: no recent commits to `shared-gh-wrappers.sh` in last 48h
- [x] File refs verified: `.agents/scripts/shared-gh-wrappers.sh` (existing wrapper layer), `.agents/scripts/pageindex-generator.py` (index generation), `tools/context/pageindex.md`
- [x] Tier: `tier:standard` — CLI surface + thin platform abstraction; existing wrapper pattern at `shared-gh-wrappers.sh` to model on

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P0 (knowledge plane skeleton)

## What

Ship the `aidevops knowledge add|list|search` CLI surface for adding sources to the inbox, listing staged/promoted sources, and searching the index. Route all platform-touching operations (PR creation, issue references, gh queries) through a new platform abstraction layer so future Gitea/GitLab/local-only adapters slot in cleanly.

**Concrete deliverables:**

1. `aidevops knowledge add <path|url>` — copies/downloads to `_knowledge/inbox/<source-id>/`, creates `meta.json` skeleton (sensitivity defaults to detector output once P0.5a lands; placeholder until then)
2. `aidevops knowledge list [--state inbox|staging|sources|all] [--kind <type>]` — lists sources with state, kind, sha, sensitivity
3. `aidevops knowledge search <query> [--scope repo|personal|both]` — substring + meta-field search (full RAG arrives in P1c with PageIndex; this is the v1 grep-and-jq baseline)
4. **Platform abstraction layer** — new `scripts/platform-helper.sh` exposing `platform_create_pr|platform_get_issue|platform_comment_issue` etc. that dispatch to `gh` / `glab` / `tea` / local (no-op) based on `repos.json: platform` field
5. All knowledge CLI internals call `platform_*` functions, never `gh` directly
6. Existing helpers stay unchanged — abstraction is opt-in, not a forced migration in this task

## Why

The CLI is the user's only entry point to the plane — without it, the directory contract from t2842 is unusable. The platform abstraction is necessary because Gitea support is stated in the parent brief as in-MVP scope (abstraction layer only, gh-only impl). Without abstraction baked in from day one, every new helper would re-add the gh/glab/tea branching, and the migration debt grows compound.

## How (Approach)

1. **Define platform interface** — write `scripts/platform-helper.sh` with functions:
   - `platform_detect <repo_path>` — returns `github|gitea|gitlab|local` from `repos.json` or remote URL fallback
   - `platform_create_issue <slug> <title> <body_file> <labels>` — wraps `gh issue create` / `glab issue create` / `tea issues create` / no-op for local
   - `platform_get_issue <slug> <num>` — wraps view operations
   - `platform_comment_issue <slug> <num> <body_file>` — wraps comment operations
   - `platform_create_pr <slug> <title> <body_file> <base> <head>`
   - For `local`: log to a file, no remote operation; for `gitea`/`gitlab`: stubs that exit 1 with a clear "P9 task — adapter not implemented" message
2. **Implement knowledge-helper.sh subcommands** (extends t2842's helper or replaces with a richer one):
   - `knowledge-helper.sh add <path|url>` — handles file copy / curl download / size check / sha256 / 30MB threshold dispatch / meta.json bootstrap
   - `knowledge-helper.sh list` — reads `_knowledge/sources/*/meta.json` (and `inbox/*/meta.json`, `staging/*/meta.json`) and pretty-prints (jq-driven)
   - `knowledge-helper.sh search <query>` — substring grep over meta.json fields + extracted text (simple v1; PageIndex tree comes in t2849)
3. **CLI wiring** — extend `bin/aidevops` (or wherever t2842 added `knowledge init`) with the new subcommands.
4. **URL handling** — detect URL vs path; for URLs, `curl -L --max-filesize <PROVISIONED_LIMIT>` to inbox; bail if size exceeds threshold without explicit `--allow-large` flag.
5. **30MB threshold dispatch** — if file size ≥ 30MB, write the original to `~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/<source-id>/<filename>` and put a stub at `_knowledge/sources/<id>/blob_pointer.txt` with sha+path; otherwise put original directly in `_knowledge/sources/<id>/`.
6. **Tests** — `tests/test-knowledge-cli.sh` covers add (file/URL), list filters, search, threshold dispatch, platform abstraction unit tests

### Files Scope

- NEW: `.agents/scripts/platform-helper.sh`
- EDIT: `.agents/scripts/knowledge-helper.sh` (extends t2842's stub with add/list/search)
- EDIT: `.agents/cli/aidevops` (or wherever main CLI lives; verify with t2842 changes)
- NEW: `.agents/tests/test-knowledge-cli.sh`
- NEW: `.agents/tests/test-platform-helper.sh`
- EDIT: `.agents/aidevops/knowledge-plane.md` (CLI usage section)

## Acceptance Criteria

- [ ] `aidevops knowledge add /path/to/file.pdf` copies to inbox with correct sha256 + meta.json
- [ ] `aidevops knowledge add https://example.com/doc.pdf` downloads, validates size, places in inbox or blob store per threshold
- [ ] `aidevops knowledge list` shows all known sources across inbox/staging/sources with state column
- [ ] `aidevops knowledge list --state staging --kind document` filters correctly
- [ ] `aidevops knowledge search <query>` returns matching source IDs with brief context
- [ ] All platform operations route through `platform_*` functions; no direct `gh` calls in `knowledge-helper.sh`
- [ ] `platform_create_issue` works against GitHub (real call); fails gracefully with clear message for `gitea`/`gitlab` (P9 not yet implemented)
- [ ] `platform: "local"` mode: knowledge add/list/search work without any remote operations
- [ ] ShellCheck zero violations on new + modified helpers
- [ ] Tests pass: `bash .agents/tests/test-knowledge-cli.sh && bash .agents/tests/test-platform-helper.sh`
- [ ] Documentation: `.agents/aidevops/knowledge-plane.md` updated with CLI section + platform abstraction overview

## Dependencies

- **Blocked by:** parent t2840 planning PR merge
- **Soft-blocked by:** t2842 (need directory contract + meta.json schema; can develop in parallel against draft contract)
- **Blocks:** t2844 (review gate routine), t2848-t2849 (P1 enrichment uses CLI to iterate over sources)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Architecture summary"
- Pattern to follow: `.agents/scripts/shared-gh-wrappers.sh` (existing platform-aware wrapper layer)
- Existing CLI dispatcher (verify path): `.agents/cli/aidevops` or `bin/aidevops`
- Sibling helpers for style: `.agents/scripts/contacts-helper.sh`, `.agents/scripts/quickfile-helper.sh`

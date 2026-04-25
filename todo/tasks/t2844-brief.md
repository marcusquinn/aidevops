---
mode: subagent
---

# t2844: knowledge plane directory contract + provisioning

## Pre-flight

- [x] Memory recall: `directory provisioning setup.sh` → no relevant lessons (new framework primitive)
- [x] Discovery: no recent commits/PRs touch `setup.sh` or `repos.json` provisioning paths in last 48h
- [x] File refs verified: `.agents/setup.sh`, `~/.config/aidevops/repos.json` (schema in `reference/repos-json-fields.md`)
- [x] Tier: `tier:standard` — mechanical directory contract + JSON config + provisioning logic; existing pattern (`.agents/` provisioning) to follow

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P0 (knowledge plane skeleton)

## What

Define and provision the `_knowledge/` directory contract in any aidevops-managed repo, gated by a new `knowledge: off | repo | personal` field in `repos.json`. Ship an `aidevops knowledge init` CLI to flip a repo from `off` → `repo` (or `personal`). Update `setup.sh` to provision the skeleton on `init` and on first `update` after the field is set.

**Concrete deliverables:**

1. Add `knowledge` field to `repos.json` schema with three values
2. Document the directory contract: `_knowledge/inbox/`, `_knowledge/staging/`, `_knowledge/sources/`, `_knowledge/index/`, `_knowledge/collections/`, `_config/knowledge.json`
3. Personal plane skeleton at `~/.aidevops/.agent-workspace/knowledge/` (same structure)
4. `.gitignore` rules for `inbox/`, `staging/` (gitignored — pre-review zone), `sources/` (versioned)
5. 30MB threshold logic: originals ≥30MB go to `~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/<source-id>/` with hash+pointer in `meta.json`; below threshold, in-repo
6. Source `meta.json` contract: `{id, kind, source_uri, sha256, ingested_at, ingested_by, sensitivity, trust, blob_path?, size_bytes}`
7. `aidevops knowledge init` CLI: prompt for `repo` vs `personal`, write to `repos.json`, run provisioning
8. `setup.sh` integration: skip provisioning when `knowledge: off`; provision on `init` and `update` when set

## Why

Without a contract, every repo invents its own ingestion directory layout. Without provisioning, users have to remember to create directories and `.gitignore` rules manually — high friction means low adoption. The opt-in `knowledge: off | repo | personal` field keeps existing repos unaffected while making the plane discoverable.

`personal` mode (cross-repo, in `~/.aidevops/.agent-workspace/knowledge/`) covers the use case of "knowledge that doesn't belong to any one repo yet" or "knowledge that spans multiple repos" — important for early-stage work where a repo might not yet exist.

## How (Approach)

1. **Update `repos.json` schema** — add `knowledge: "off" | "repo" | "personal"` (default `"off"` for backwards compat). Update `reference/repos-json-fields.md` with the new field.
2. **Define directory contract** — write `.agents/aidevops/knowledge-plane.md` documenting:
   - Directory layout (inbox/staging/sources/index/collections)
   - `meta.json` schema (with version key for forward-compat)
   - 30MB threshold rationale
   - Personal vs repo plane semantics
3. **Add `knowledge` subcommand to aidevops CLI** — extend `bin/aidevops` (or `cli/main.sh`) with `knowledge init|status` subcommands. `init` prompts for mode, writes to `repos.json`, calls provisioning helper.
4. **Provisioning helper** — new `scripts/knowledge-helper.sh provision <repo-path>` that creates the directory tree, writes `.gitignore` rules, creates `_config/knowledge.json` with defaults.
5. **Integrate with `setup.sh`** — extend `_initialize_repo()` and `_update_repo()` to call `knowledge-helper.sh provision` when `knowledge != "off"`.
6. **Standard `.gitignore` template** — `.agents/templates/knowledge-gitignore.txt` containing the entries for `inbox/`, `staging/` (and a comment explaining why `sources/` is intentionally NOT ignored).

### Files Scope

- NEW: `.agents/scripts/knowledge-helper.sh`
- NEW: `.agents/aidevops/knowledge-plane.md`
- NEW: `.agents/templates/knowledge-gitignore.txt`
- NEW: `.agents/templates/knowledge-config.json` (default `_config/knowledge.json`)
- EDIT: `.agents/cli/aidevops` (or wherever the main CLI dispatcher lives — verify path)
- EDIT: `.agents/setup.sh` (add knowledge provisioning hook in `_initialize_repo` / `_update_repo`)
- EDIT: `.agents/reference/repos-json-fields.md` (add `knowledge` field)
- EDIT: `.agents/AGENTS.md` (add knowledge to plane index in Quick Reference)

## Acceptance Criteria

- [ ] `aidevops knowledge init` (interactive) writes `knowledge: "repo"` (or `"personal"`) to `~/.config/aidevops/repos.json` for the current repo
- [ ] After `init`, the directory tree exists at `_knowledge/{inbox,staging,sources,index,collections}` with correct `.gitignore`
- [ ] `_config/knowledge.json` exists with default sensitivity policy and trust ladder placeholders
- [ ] Personal mode provisions at `~/.aidevops/.agent-workspace/knowledge/` instead of in-repo
- [ ] `setup.sh --update` re-provisions if directories were deleted (idempotent)
- [ ] Existing repos with `knowledge` unset (or `"off"`) are unaffected by `setup.sh --update`
- [ ] ShellCheck zero violations on new helper
- [ ] Tests: `tests/test-knowledge-provisioning.sh` covers: fresh init, idempotent update, personal mode, off mode no-op, gitignore correctness
- [ ] Documentation: `.agents/aidevops/knowledge-plane.md` written with full directory contract spec

## Dependencies

- **Blocked by:** parent t2840 planning PR merge
- **Blocks:** t2843 (CLI surface needs directory contract), t2845 (sensitivity needs meta.json schema), t2848-t2849 (P1), t2850 (cases plane references knowledge sources)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Architecture summary" + "Repo provisioning"
- Pattern to follow: `.agents/setup.sh` — existing `_initialize_repo` and `_update_repo` flow
- Schema reference: `.agents/reference/repos-json-fields.md`
- Existing personal-data location convention: `~/.aidevops/.agent-workspace/`

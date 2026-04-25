---
mode: subagent
---

# t2851: case dossier contract + `aidevops case open`

## Pre-flight

- [x] Memory recall: `case dossier matter timeline` → no relevant lessons (new framework primitive)
- [x] Discovery: cases plane is novel; no existing pattern in repo
- [x] File refs verified: parent brief at `todo/tasks/t2840-brief.md`; sibling adapter style at `.agents/scripts/contacts-helper.sh`
- [x] Tier: `tier:standard` — directory contract + JSON schema + CLI; structurally similar to t2844 (knowledge directory contract)

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P4 (cases plane)

## What

Define the `_cases/` directory contract per repo and ship `aidevops case open <slug>` to create a new case dossier. Each case has: dossier metadata (parties, kind, opened_at, deadlines, status), a chronological timeline (events JSONL), pointers to attached `_knowledge/sources/` IDs (no duplication), and dossier sub-files (notes, drafts, communications log).

**Concrete deliverables:**

1. `_cases/case-YYYY-NNNN-<slug>/` directory contract with `dossier.toon`, `timeline.jsonl`, `sources.toon` (ID list), `notes/`, `comms/`, `drafts/`
2. `dossier.toon` schema: `id, slug, kind, opened_at, parties: [...], deadlines: [...], status: open|hold|closed, related_cases: [...], related_repos: [...]`
3. Per-repo case ID scheme: `case-2026-0001-<slug>` (year + sequential number per repo + human slug); sequential counter at `_cases/.case-counter`
4. `aidevops case open <slug> [--kind <type>] [--party <name>] [--deadline <iso-date>]` — interactive prompts for missing required fields
5. Cross-case privilege firewall — design only in this task; enforced in P6a: by default each case sees only its own `sources.toon`; cross-case search requires explicit `--include-case <id>` and is logged
6. Provisioning wired into `aidevops case init` (analogous to `aidevops knowledge init`) — adds `cases: "repo"` to `repos.json` and creates skeleton

## Why

Cases are NOT a special collection of knowledge sources — they have timeline, parties, deadlines, communications semantics that don't fit `_knowledge/collections/`. Without a separate plane, every consumer would invent its own case-shaped data; with a contract, the cases plane and the comms agent (P6) compose cleanly.

Per-repo case IDs (not global) keep IDs short and meaningful for one-repo workflows. Cross-repo references via `related_cases` for the multi-repo case (rare in practice).

## How (Approach)

1. **Directory contract** — write `.agents/aidevops/cases-plane.md`:
   - Layout: `_cases/case-YYYY-NNNN-slug/{dossier.toon,timeline.jsonl,sources.toon,notes/,comms/,drafts/}`
   - `dossier.toon` schema (ToonSON for human-friendly versioned config)
   - `timeline.jsonl` event format: `{ts, kind: "note|comm|deadline|status_change|attach", actor, content, ref: <source-id|case-event-id>}`
   - `sources.toon` list format with provenance: `{id, attached_at, attached_by, role: "evidence|reference|background"}`
2. **Case helper** — `scripts/case-helper.sh`:
   - `init <repo-path>` — provisions skeleton + `cases: "repo"` in `repos.json`
   - `open <slug> [flags]` — claims next ID from `_cases/.case-counter`, creates dossier, prompts for required fields (kind, at least one party, opened_at defaults to now)
   - Internal helpers `_case_id_claim()`, `_dossier_write()`, `_timeline_append()`
3. **Case ID counter** — `_cases/.case-counter` per-repo file with current year + sequence (e.g. `2026:0014`); increment atomically with file lock; year resets sequence to 0001
4. **Provisioning integration** — same shape as P0a: `aidevops case init` flips `repos.json: cases: "repo"`, runs case provisioning helper that creates `_cases/`, `_cases/.gitignore` (gitignore drafts/ by default), `_cases/.case-counter`
5. **Tests** — covers init, open with all flags, open with prompts, ID counter atomicity, year rollover, schema validation
6. **Schema validation** — JSON Schema for `dossier.toon` so invalid edits get caught client-side

### Files Scope

- NEW: `.agents/scripts/case-helper.sh`
- NEW: `.agents/aidevops/cases-plane.md`
- NEW: `.agents/templates/cases-gitignore.txt`
- NEW: `.agents/templates/case-dossier-schema.json` (JSON Schema)
- EDIT: `.agents/cli/aidevops` (add `case` subcommand)
- EDIT: `.agents/setup.sh` (provisioning hook for `cases: "repo"`)
- EDIT: `.agents/reference/repos-json-fields.md` (add `cases` field)
- NEW: `.agents/tests/test-case-helper.sh`

## Acceptance Criteria

- [ ] `aidevops case init` writes `cases: "repo"` to `repos.json` and creates `_cases/` skeleton
- [ ] `aidevops case open dispute-2026-acme --kind dispute --party "ACME Ltd" --deadline 2026-08-31` creates `_cases/case-2026-0001-dispute-2026-acme/` with valid dossier
- [ ] `dossier.toon` validates against the schema; invalid edits are caught
- [ ] Concurrent `case open` from two sessions: each gets a unique sequential ID (lock-protected counter)
- [ ] Year rollover: opening case in 2027 starts sequence at `case-2027-0001-...`
- [ ] `timeline.jsonl` initial entry records the open event with actor + opened_at
- [ ] `sources.toon` initialised empty array
- [ ] Personal plane mode: `_cases/` at `~/.aidevops/.agent-workspace/cases/` works equivalently
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-case-helper.sh`
- [ ] Documentation: full directory contract in `.agents/aidevops/cases-plane.md`

## Dependencies

- **Blocked by:** t2844 (P0a directory contract pattern to model on; meta.json schema for cross-references), t2843 (P0b CLI dispatcher), t2846 (P0.5a sensitivity stamps need to exist before cases attach to sources)
- **Blocks:** t2852 (P4b case CLI builds on `case open`), t2853 (P4c alarming reads dossier.deadlines), all P5/P6

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Cases plane" + "Cross-case privilege firewall"
- Pattern to follow: t2844 (P0a knowledge directory contract — same shape for cases)
- Schema validation library: same `jq`/JSON Schema toolchain used elsewhere

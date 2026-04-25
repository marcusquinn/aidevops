---
mode: subagent
---

# t2852: case CLI surface (attach/status/close/archive/list)

## Pre-flight

- [x] Memory recall: `case management cli attach status` → no relevant lessons (new)
- [x] Discovery: builds on t2851 case-helper.sh; pattern-similar to knowledge-helper.sh CLI surface
- [x] File refs verified: parent brief; sibling helper at `.agents/scripts/contacts-helper.sh`
- [x] Tier: `tier:standard` — CLI surface; thin wrapper over the dossier contract

## Origin

- Created: 2026-04-25
- Parent task: t2840 / GH#20892
- Phase: P4 (cases plane)

## What

Ship the rest of the case CLI: `attach`, `status`, `close`, `archive`, `list`, `show`, `note`, `deadline`, `party`, `comm`. Each operation appends to the case's `timeline.jsonl` for an audit trail; no operation silently mutates dossier without timeline entry.

**Concrete deliverables:**

1. `aidevops case attach <case-id> <source-id> [--role evidence|reference|background]` — appends to `sources.toon`, timeline entry
2. `aidevops case status <case-id> <new-status> [--reason "..."]` — open|hold|closed; timeline entry
3. `aidevops case close <case-id> --outcome <outcome> [--summary "..."]` — sets status=closed + outcome field; final timeline entry
4. `aidevops case archive <case-id>` — moves case to `_cases/archived/` (still readable, filtered out of default list)
5. `aidevops case list [--status open|hold|closed|archived] [--kind <type>] [--party <name>]` — table output
6. `aidevops case show <case-id>` — pretty-prints dossier + timeline + attached sources
7. `aidevops case note <case-id> [--message "..."]` — appends to `notes/notes.md` and timeline
8. `aidevops case deadline add|remove <case-id> [--date ISO --label "..."]`
9. `aidevops case party add|remove <case-id> --name "..." --role "..."`
10. `aidevops case comm log <case-id> --direction in|out --channel <c> --summary "..."` — communications log entry (full email content lands later via P5; this is for paper-trail entries)

## Why

The dossier contract from t2851 is unusable without operations on it. Without `attach`, sources can't be linked to cases. Without `status` and `close`, lifecycle is opaque. Without `list`, users can't find their open cases. Without `note`, ad-hoc context has nowhere to live.

Every mutation appends to `timeline.jsonl` because cases are audit-trail-driven (legal/dispute work especially) — silent mutation defeats the value.

## How (Approach)

1. **Extend `case-helper.sh`** with the 9 subcommands above (one function each, sharing common `_dossier_load`/`_timeline_append`/`_dossier_save` helpers from t2851)
2. **`attach` semantics** — verify source exists in `_knowledge/sources/<id>/`; refuse to attach inbox/staging items; record `attached_at, attached_by, role` in `sources.toon`; timeline entry with source-id and role
3. **`status` and `close`** — `close` is `status closed --outcome <x>` shorthand; closing with no outcome → fail with friendly error; timeline entries always include actor + reason
4. **`archive` move** — `git mv _cases/case-... _cases/archived/case-...`; archive timeline entry; subsequent operations on archived cases require `--unarchive` flag
5. **`list` output** — default table: `case-id | slug | kind | status | parties | open_date | next_deadline`; flags filter; `--json` flag for machine output
6. **`show` formatting** — dossier as markdown header; timeline as chronological list; attached sources as bullet list with kind + sensitivity stamps; deadlines as "in X days" relative
7. **`note` and `comm`** — both append to dossier sub-files AND timeline (timeline pointer to file location); `note` is internal context; `comm` is communications log
8. **Tests** — covers each subcommand happy path + at least one failure path (e.g., attach non-existent source, close without outcome, list with no matches)
9. **JSON output mode** — every read-side subcommand (`list`, `show`) supports `--json` for scripting

### Files Scope

- EDIT: `.agents/scripts/case-helper.sh` (extend with 9 subcommands)
- EDIT: `.agents/cli/aidevops` (route subcommands)
- EDIT: `.agents/aidevops/cases-plane.md` (CLI section)
- NEW: `.agents/tests/test-case-cli.sh`

## Acceptance Criteria

- [ ] `aidevops case attach <case-id> <source-id> --role evidence` appends to `sources.toon` and timeline; refuses attach to non-promoted sources
- [ ] `aidevops case status <case-id> hold --reason "awaiting client response"` updates dossier + timeline
- [ ] `aidevops case close <case-id> --outcome settled --summary "..."` sets status=closed + outcome + summary; refuses close-without-outcome
- [ ] `aidevops case archive <case-id>` moves dir to `_cases/archived/` and adds timeline entry
- [ ] `aidevops case list` shows open cases by default; `--status all` shows closed+archived too
- [ ] `aidevops case list --party "ACME Ltd"` filters
- [ ] `aidevops case show <case-id>` produces a readable markdown dossier
- [ ] `aidevops case note <case-id> --message "..."` appends to notes/notes.md AND timeline
- [ ] `aidevops case deadline add <case-id> --date 2026-08-31 --label "filing deadline"` updates dossier and timeline
- [ ] All operations refuse on archived cases unless `--unarchive`
- [ ] All operations support `--json` mode for machine consumption
- [ ] ShellCheck zero violations
- [ ] Tests pass: `bash .agents/tests/test-case-cli.sh`

## Dependencies

- **Blocked by:** t2851 (P4a case dossier contract + `case open`)
- **Soft-blocked by:** t2844 (P0a — sources must exist to attach)
- **Blocks:** t2853 (P4c alarming reads case list and dossier deadlines), P5c (filter→case-attach uses `attach`), P6 (drafts and chasers operate on cases)

## Reference

- Parent brief: `todo/tasks/t2840-brief.md` § "Cases plane CLI"
- Sibling pattern: `.agents/scripts/contacts-helper.sh` (CLI surface for contacts; similar idempotent JSON-edit pattern)
- Pattern for archive: `git mv` semantics + status filter (similar to closed-issue handling in `gh`)

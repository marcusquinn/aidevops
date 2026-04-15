<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2114: feat(issue-sync): `backfill-sub-issues` subcommand — parent-child links from GH state alone

## Origin

- **Created:** 2026-04-15
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (same awardsapp investigation as t2112)
- **Parent task:** none
- **Conversation context:** `issue-sync-helper.sh relationships` already syncs blocked-by and sub-issue hierarchy to GitHub — but it keys off `TODO.md` entries with `ref:GH#NNN`. An issue created outside the aidevops machinery (no TODO entry, no brief, no sync path) is invisible to this command even if its body clearly declares `Parent: tNNN` or dot-notation in the title. GH#18735 already added the `_gh_auto_link_sub_issue` hook to `gh_create_issue`, but only new issues created through that wrapper benefit — bare `gh issue create` still slips through. Existing labelless / unlinked issues on awardsapp (`t325.2` .. `t325.7` → parent `t325` / `#2385`) are the concrete backfill case; the same pattern will recur whenever a session bypasses the wrapper.

## What

New subcommand `issue-sync-helper.sh backfill-sub-issues [--repo SLUG] [--issue N]` that operates purely on GitHub state — no `TODO.md` or brief file required:

1. Lists candidate issues (either a single `--issue N` or all open issues in the repo).
2. For each, detects a parent reference via (in priority order):
   a. **Dot-notation in title** — `^(t\d+)(\.\d+): ` → parent `t\1`.
   b. **`Parent: tNNN` / `Parent: #NNN` line in body** — regex-anchored.
   c. **`Blocked by: tNNN` pattern where the referenced task has `parent-task` label on GitHub** — mirror of the `_is_parent_tagged_task` logic but reading GitHub instead of `TODO.md`.
3. Resolves the parent to a GitHub issue number via title prefix search (`gh issue list --search "tNNN: in:title"` → pick the one whose title starts with `"tNNN: "`).
4. Resolves both child and parent to node IDs via `_cached_node_id` and calls `_gh_add_sub_issue`.
5. Idempotent — the `addSubIssue` mutation already suppresses "duplicate sub-issues" and "only have one parent" errors. Running the command twice is safe.
6. `--dry-run` preview mode (shared `DRY_RUN` flag).

## Why

The existing `cmd_relationships` is the TODO-driven entry point. `_gh_auto_link_sub_issue` is the wrapper-driven entry point. Neither handles the "issue already exists, no TODO, wrapper bypassed" case — which is exactly the awardsapp backfill we need to run.

Having a dedicated subcommand also makes it easy to invoke from `pulse-issue-reconcile.sh reconcile_labelless_aidevops_issues` (t2112) as a targeted one-issue call, closing the loop: reconcile detects the labelless child, calls `backfill-sub-issues --issue N`, parent-child link appears.

The `backfill-sub-issues` name is the natural extension of the existing `relationships` subcommand vocabulary; keeping it distinct (not a `--mode` flag on `relationships`) avoids ambiguity about which data source is authoritative (TODO vs GH).

## Tier

### Tier checklist

- [x] 2 or fewer files to modify — **false**, 3 (`issue-sync-helper.sh` function + `cmd_help` entry + test file)
- [x] Every target file under 500 lines — **false**, `issue-sync-helper.sh` is 1859 lines
- [x] No judgment calls — detection patterns are specified
- [x] Estimate 1h or less — tight but achievable
- [x] 4 or fewer acceptance criteria — **false**, 5 below

**Selected tier:** `tier:standard` — new function in a 1700-line file, reuses existing helpers (`_cached_node_id`, `_gh_add_sub_issue`, `gh_find_issue_by_title`).

## PR Conventions

Leaf task. PR body uses `Resolves #NNN`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/issue-sync-helper.sh` — add `cmd_backfill_sub_issues` function + dispatch in `main()` + `cmd_help` entry. Add a small helper `_detect_parent_from_gh_state` that encapsulates the 3-way detection.
- NEW: `.agents/scripts/tests/test-backfill-sub-issues.sh` — stubbed `gh` harness, exercises all 3 detection paths.

### Implementation Steps

**Step 1 — add `_detect_parent_from_gh_state` helper.** Takes `(child_num, child_title, child_body, repo)`. Returns the parent issue number via stdout, or empty string.

- Pattern 1: `echo "$child_title" | grep -oE '^(t[0-9]+)\.[0-9]+:'` → extract `tNNN`. Search for parent via `gh_find_issue_by_title "$repo" "tNNN: "`.
- Pattern 2: `echo "$child_body" | grep -oE '^Parent:[[:space:]]*t[0-9]+(\.[0-9]+)*'` → extract task id. Same title search.
- Pattern 3: `echo "$child_body" | grep -oE '^Parent:[[:space:]]*#[0-9]+'` → direct number.
- Return the first non-empty match.

**Step 2 — add `cmd_backfill_sub_issues`.** Iterates open issues (or single `--issue`), resolves child node ID, calls `_detect_parent_from_gh_state`, resolves parent node ID, calls `_gh_add_sub_issue`. Prints a `Sub-issues linked: N` summary.

**Step 3 — wire the new argument parsing.** Add `--issue N` to the main arg-parse loop. Add `backfill-sub-issues` to the `case "$command"` dispatch. Add help text.

**Step 4 — test harness.** Stubs `gh` to respond to:

- `gh issue list --state open --json number,title,body,labels` → canned array covering dot-notation, Parent-tNNN, Parent-#NNN, and unrelated shapes.
- `gh api graphql` → respond to `addSubIssue` mutations with success; record calls to a trace file.
- `gh issue view --json ...` / `gh issue list --search` for the parent resolution.

Assert the trace file contains exactly the expected `addSubIssue` calls for the 3 detection paths and none for the unrelated shape.

### Verification

```bash
cd /Users/marcusquinn/Git/aidevops-feature-t2112-pulse-labelless-reconcile-gh-wrapper-sub-issue-body
shellcheck .agents/scripts/issue-sync-helper.sh
bash .agents/scripts/tests/test-backfill-sub-issues.sh

# Real-world smoke test (after PR merges):
issue-sync-helper.sh backfill-sub-issues --repo awardsapp/awardsapp --dry-run
# Expected: dry-run plan linking #2395..#2400 as sub-issues of #2385
```

## Acceptance Criteria

1. `issue-sync-helper.sh backfill-sub-issues --help` prints usage including `--repo` and `--issue` flags.
2. Dot-notation titles (`t325.2: ...`) are detected and linked to parent `t325` issue.
3. `Parent: tNNN` body line is detected and linked to the matching parent.
4. `Parent: #NNN` body line is detected and linked directly.
5. `--dry-run` prints the plan without mutating GitHub state.
6. Test harness covers all 3 detection paths and passes.
7. Shellcheck clean on `issue-sync-helper.sh`.

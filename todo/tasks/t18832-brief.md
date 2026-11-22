<!-- aidevops:brief-schema=v2 -->

## Origin

Interactive fleet-health review (session objective: stop excessive automated comments on stale issues). Evidence: issue #36227 received a misleading "Partial Parent Closeout" comment after planning-only PR #36229 merged.

## What

Skip the post-merge "Partial Parent Closeout" comment when the merged PR is a planning publication (body carries `<!-- aidevops:planning-publication:v1 ... -->`). Planning PRs only publish `TODO.md`/`todo/` entries and use `For #NNN` so they do not close the task they announce; they deliver no task scope.

## Why

`shared-todo-commit.sh` (`_todo_planning_pr_body`, around `:410-439`) writes `- For #NNN` for every task in a planning PR. On merge, `_pm_handle_partial_parent_closeout` (`.agents/scripts/pulse-merge-issue-closeout.sh:125-182`) treats that reference as a parent delivery. `_pm_issue_needs_partial_closeout` (`:73-93`) classifies nearly every worker-ready brief as a "broad parent", because briefs contain an `Acceptance Criteria` heading and 2+ checklist items. The result is a comment on a fresh leaf task that claims "PR #N merged against this broad parent", repeats the task's own acceptance criteria as "follow-ups", and copies the interactive session's cost signature from the planning PR body.

GitHub search on 2026-10-31 found 45 issues carrying a "Partial Parent Closeout" comment generated from a planning publication PR, out of 148 partial closeouts overall.

## Tier

`tier:simple`: one guard in one function, plus one regression case in the existing suite.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-merge-issue-closeout.sh`: in `_pm_extract_partial_parent_reference` (`:56-65`), return an empty reference when the PR body contains `aidevops:planning-publication:v1`.
- `EDIT: .agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh`: add one case: a planning publication body with `- For #23932` and a brief-shaped issue body posts no comment and makes no issue fetch.

### Complete Write Surface

- **Callers/readers:** `_handle_post_merge_actions` (`.agents/scripts/pulse-merge.sh:1072`) is the only caller. Test stubs in `test-pulse-merge-routine-standalone.sh`, `test-pulse-merge-post-merge-label-fetch.sh` and `test-pulse-merge-parent-task-close-guard.sh` replace the function and are unaffected.
- **Writers/mutation paths:** removes one GitHub issue-comment write for planning PRs. No label or state changes.
- **Existing verification/tests:** `test-pulse-merge-partial-parent-closeout.sh`.
- **Schemas/config:** reads the existing planning publication marker written by `shared-todo-commit.sh`; marker format unchanged.
- **Generated/deployed mirrors:** deployed by `setup.sh` on the normal update path.
- **Migrations/backfills:** none. Existing comments stay as historical records.
- **Cleanup/rollback paths:** revert the guard.

### Implementation Steps

1. Add the marker guard after the PR body fetch in `_pm_extract_partial_parent_reference`; keep `return 0` semantics.
2. Add the regression case and run the verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** read-only guard; no new writes.
- **Mixed-version/backward compatibility:** older runners keep posting until updated; the PR-number dedup marker still prevents duplicates.
- **Idempotency/retry:** unchanged.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh
shellcheck .agents/scripts/pulse-merge-issue-closeout.sh .agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh
```

- **Surface mapping:** the suite covers both the new skip and the existing parent closeout behaviour.
- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/scripts/pulse-merge-issue-closeout.sh`
- `.agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh`

## Acceptance Criteria

- [ ] A merged planning publication PR (`aidevops:planning-publication:v1` marker) referencing `For #NNN` posts no partial parent closeout comment.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh"
  ```

- [ ] Existing For/Ref closeouts on genuine parents still post exactly once (existing cases pass).

## Context & Decisions

- Not narrowing `_pm_issue_needs_partial_closeout` here: genuine unlabelled parents still rely on its heuristics. The planning marker is an exact, producer-owned signal.
- Related: GH#23937 (partial closeout origin), GH#21426 (library extraction).

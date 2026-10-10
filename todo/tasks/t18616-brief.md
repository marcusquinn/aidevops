## What

`full-loop-helper.sh commit-and-pr` must not close or mark in-review the implementation issue when the PR diff touches only planning files (`TODO.md`, `todo/**`). For a planning-only diff use the non-closing `For #N` keyword and skip `_label_issue_in_review`, so the issue stays dispatchable.

## Why

Observed with t18614 (GH#33978): a planning-only PR (#33980, adding only `todo/tasks/t18614-brief.md`) was opened with `commit-and-pr --issue 33978`. The generated body contained `Resolves #33978` (`closing_keyword` defaults to `Resolves` at `.agents/scripts/full-loop-helper.sh:169`; only parent-task and completion-bookkeeping switch it to `For`). Merging it would have closed the unimplemented auto-dispatch issue; the session caught it and hand-edited the body. Separately, `_label_issue_in_review` (`full-loop-helper.sh:312`) left the issue `status:in-review` after merge, which hides it from the dispatch queue until manually reset to `status:available`.

## Tier

tier:standard — one detection helper plus two conditional branches in a known function; follows the existing parent-task `For` precedent.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Keyword selection: .agents/scripts/full-loop-helper.sh:184-208 (_commit_and_pr_prepare_metadata)
#    precedent: completion_bookkeeping (:185-187) and parent-task (:205-207) set closing_keyword="For".
#    files_changed is computed at :190 from git diff --name-only "${base_ref}..HEAD".
# 2. Labelling: .agents/scripts/full-loop-helper.sh:307-313 (_commit_and_pr_publish) — gate _label_issue_in_review.
# 3. Gotcha: --allow-parent-close (:203-204) forces Resolves; planning-only detection must come after it and
#    must not override an explicit --allow-parent-close.
```

### Files to Modify

- `EDIT: .agents/scripts/full-loop-helper.sh:184-208` — add `_diff_is_planning_only "$base_ref"` (new helper in the same file, explicit `return 0/1`): true when every `git diff --name-only "${base_ref}..HEAD"` path is `TODO.md` or under `todo/`, and the diff is non-empty. When true and `allow_parent_close` is 0, set `closing_keyword="For"`, set a local `planning_only=1`, and `print_info "Planning-only diff — using 'For' keyword; issue stays dispatchable"`.
- `EDIT: .agents/scripts/full-loop-helper.sh:312` — skip `_label_issue_in_review` when `planning_only=1` (PR label at :313 unchanged).

### Complete Write Surface

- **Callers/readers:** `_commit_and_pr_prepare_metadata` and `_commit_and_pr_publish` are called only from `commit-and-pr` in the same file (`rg -n "_commit_and_pr_prepare_metadata|_commit_and_pr_publish" .agents/scripts/`). `planning_only` must be visible to both (declare it beside `closing_keyword` at :169).
- **Writers/mutation paths:** PR body text and the issue status label only.
- **Existing verification/tests:** `.agents/scripts/tests/test-full-loop-parent-task.sh` covers `For`/`Resolves` selection; `.agents/scripts/tests/test-full-loop-runtime-risk.sh` covers `_build_pr_body`. Both must still pass.
- **Schemas/config:** N/A — no config.
- **Generated/deployed mirrors:** deployed by `setup.sh`; no generated output.
- **Migrations/backfills:** N/A.
- **Cleanup/rollback paths:** revert PR.

### Implementation Steps

1. Add `_diff_is_planning_only` near `_commit_and_pr_prepare_metadata`; use `git diff --name-only`, loop paths, `case "$path" in TODO.md|todo/*) ;; *) return 1 ;; esac`.
2. Declare `local planning_only=0` next to `closing_keyword` (:169); set it in prepare_metadata after the parent-task branch, guarded by `allow_parent_close -eq 0`.
3. Gate `_label_issue_in_review` on `planning_only -eq 0`.
4. Run existing tests, shellcheck, then a dry check: in a worktree with only a `todo/tasks/` change, confirm the composed body says `For #N`.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A.
- **Migration/rollback:** N/A.
- **Mixed-version/backward compatibility:** mixed diffs (planning + code) keep `Resolves`; worker linkage repair at :308 only runs for `Resolves`, so planning-only worker PRs skip it, which is intended.
- **Idempotency/retry:** reruns recompute from the same diff.
- **Partial failure/recovery:** unchanged.

### Complexity Impact

- **Target function:** `_commit_and_pr_prepare_metadata` in `.agents/scripts/full-loop-helper.sh`
- **Current line count:** ~49 lines (threshold: 100)
- **Estimated growth:** +5 lines (detection lives in a new helper)
- **Projected post-change:** ~54 lines (54%)
- **Action required:** None

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-full-loop-parent-task.sh
bash .agents/scripts/tests/test-full-loop-runtime-risk.sh
shellcheck .agents/scripts/full-loop-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** parent-task test proves keyword precedence still holds; runtime-risk test proves body composition unchanged; shellcheck/linters cover the new helper.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not change `_build_pr_body`, the parent-task keyword guard, or `planning-commit-helper.sh`.

**AI brief owner:** marcusquinn interactive session.

### Files Scope

- `.agents/scripts/full-loop-helper.sh`

## Acceptance Criteria

- [ ] `commit-and-pr --issue N` on a branch whose diff is only `TODO.md` and/or `todo/**` produces a PR body with `For #N` (no `Resolves`/`Closes`/`Fixes`) and leaves issue N's status label unchanged.
- [ ] A diff that includes any non-planning file still produces `Resolves #N` and labels the issue `status:in-review`; `--allow-parent-close` still forces `Resolves`.
- [ ] Existing full-loop parent-task and runtime-risk tests pass; shellcheck clean.

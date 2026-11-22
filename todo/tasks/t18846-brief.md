## What

The pulse deterministic merge posts a "Partial Parent Closeout" comment on every issue referenced by a TODO-projection PR, including closed leaf issues. The comment says "the parent remains open", which is false, adds comment noise, and is parsed as a cost receipt by `dispatch-dedup-cost.sh`.

## Why

Observed in `pulse.log` (`posted partial parent closeout on issue`). All three aidevops cases are false positives on CLOSED leaf bug issues:

- PR #36297 (`aidevops/issue-sync-todo`, issue-sync TODO projection, `Ref #36292`) → comment on closed #36292.
- PR #36131 (`aidevops/issue-sync-todo`) → comment on closed #36122.
- PR #36226 (`aidevops/pulse-todo-*`, pulse TODO handoff, `Ref #36061`) → comment on closed #36061.

Root causes in `.agents/scripts/pulse-merge-issue-closeout.sh`:

1. `_pm_extract_partial_parent_reference` exempts only planning-publication PRs (HTML-comment marker `aidevops:planning-publication:v1`, GH#36230). The two sibling projection PRs deliver no task scope either: marker `aidevops:issue-sync-todo-pr` (`issue-sync-git-push-helper.sh` `ISSUE_SYNC_PR_MARKER`) and marker `aidevops:pulse-todo-handoff id=<sha>` (`pulse-todo-publication.sh`). Both list non-closing `Ref #N` lines for audit linkage only.
2. `_pm_handle_partial_parent_closeout` never checks issue state. A closed issue has no open parent scope to describe.
3. `_pm_issue_needs_partial_closeout` matches words such as `acceptance criteria` / `lifecycle`, which almost every brief-format issue contains, so the two gates above are the effective filter.

`dispatch-dedup-cost.sh` counts `PARTIAL_PARENT_CLOSEOUT` comments as cost receipts, so a spurious closeout copied onto an open issue could also inflate its cost accounting.

## How

1. `_pm_extract_partial_parent_reference`: return no parent for bodies carrying the issue-sync or pulse-todo-handoff HTML-comment markers, next to the existing planning-publication exemption. Marker-only matching is safe: a forged marker can only suppress a comment.
2. `_pm_handle_partial_parent_closeout`: read `.state` from the already-fetched issue JSON (no extra API call) and return early when it is `closed`.
3. Extend `.agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh` with one case per new guard, following the existing planning-publication case.

### Files Scope

- `.agents/scripts/pulse-merge-issue-closeout.sh`
- `.agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh`

## Verification

- `shellcheck` clean on both files.
- `bash .agents/scripts/tests/test-pulse-merge-partial-parent-closeout.sh` passes, including the new issue-sync, pulse-todo and closed-issue cases.
- Production: after deploy, the next merged issue-sync or pulse-todo PR logs no `posted partial parent closeout` line.

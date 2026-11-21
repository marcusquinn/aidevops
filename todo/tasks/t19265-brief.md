## What

Make dispatch dedup treat an open, ready orphan-recovery PR as in-flight work for its issue while required checks or review are still pending, so pulse does not dispatch a second worker that starts from the base branch without the recovered progress.

## Why

`_attempt_orphan_recovery_pr` (`.agents/scripts/shared-claim-lifecycle.sh:601-745`) opens a non-draft PR titled `GH#N: chore: auto-recover orphaned worker branch`, labelled `origin:worker-takeover`, with a non-closing standalone `For #N` line and an `<!-- aidevops:orphan-recovery … -->` marker (`_build_orphan_recovery_pr_body`, `:468-491`). The issue is released to `status:available`.

`has_open_pr` (`.agents/scripts/dispatch-dedup-pr.sh:1420`) misses this PR in busy repositories:

- Check 0 (`_has_open_pr_check_healthy_sibling`, `:824-906`) finds it through the issue-scoped search, but only counts non-draft siblings that are approved or mergeable and rejects `mergeStateStatus` `BLOCKED`. A recovery PR is `BLOCKED` while required checks run.
- Check 1 (`_has_open_pr_check_open_commits`, `:923`) would match the `GH#N` title, but reads only the 10 newest open PRs (`_ddpr_graphql_open_commits`, `pullRequests(first: 10)`).
- Check 1b only matches closing keywords. The `For #N` reference is non-closing by design (GH#32933).

Observed in a managed repository with 66 open PRs and about one new worker PR per minute: `dispatch-dedup-helper.sh has-open-pr <issue> <repo>` returned exit 1 while the issue's ready recovery PR was open. A second runner then launched a fresh worker on that issue. It spent 11 minutes recreating the same four specs and closed the recovery PR as superseded. In five other cases the recovery PRs had to be converted to drafts by hand to stop redispatch. Ready recovery PRs normally merge and their issues close, so the only defect is the redispatch race before merge.

### Files Scope

- `.agents/scripts/dispatch-dedup-pr.sh`
- `.agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh`

## How

- In `_has_open_pr_check_healthy_sibling`'s non-draft `match_pr` jq selection, also accept a recovery checkpoint: same-repository PR, label `origin:worker-takeover`, body containing the `<!-- aidevops:orphan-recovery` marker (followed by a space) and a standalone `For #N` line for this issue. Keep `CHANGES_REQUESTED` excluded. Exclude `DIRTY`/`CONFLICTING`, because a conflicted PR cannot land and must not hold the issue. Allow `BLOCKED`, which only means checks or review are pending in the pulse merge pipeline.
- Emit a distinct reason for the recovery match. Keep the existing `is approved or mergeable` text unchanged for healthy siblings.
- Leave planning-only `For #N` PRs, drafts (handled by `_ddpr_classify_sibling_drafts`) and Check 1's window unchanged.

## Acceptance

- `bash .agents/scripts/tests/test-dispatch-dedup-helper-has-open-pr.sh` passes. New cases: a ready `origin:worker-takeover` recovery body with `mergeStateStatus: BLOCKED` blocks; the same PR with `DIRTY` does not; a `BLOCKED` `For #N` PR without the recovery marker does not.
- Live evidence: in a repository with more than ten newer open PRs, the issue-scoped sibling search returns the older recovery PR (`has-open-pr` reports `WORKER_DRAFT_CHECKPOINT` for a draft one). A real recovery PR body matches both the marker and the standalone `For #N` predicate. When a ready recovery PR is open, `has-open-pr <issue> <repo>` from the worktree exits 0 with the `open recovery PR` reason.
- `shellcheck .agents/scripts/dispatch-dedup-pr.sh` reports no violations.

## What

Make the worker watchdog's pre-kill WIP push count commits against the repository's real PR base branch instead of a hard-coded `origin/main` (then `origin/master`), so it pushes exactly when the worker has its own unpushed commits.

## Why

`_push_wip_before_kill` (`.agents/scripts/worker-activity-watchdog.sh:527-566`, t2923) runs `git rev-list --count origin/main..HEAD`, falling back to `origin/master..HEAD` only when the first count is 0. This bypasses the shared resolver `aidevops_pr_base_branch` (`.agents/scripts/shared-pr-base.sh`, GH#39167), which exists because hard-coded `main` broke repos whose integration branch is `develop`/`dev`.

Observed on this runner: in a managed repo whose GitHub default branch is `develop`, `origin/main` is a release branch last updated 2026-04-28 and 19,715 commits behind `origin/develop`. Every `[WATCHDOG_WIP_PUSH]` line in local worker failure excerpts from 2026-11-20 to 2026-11-21 (64 kills) reports `ahead=` between 18,256 and 19,681. Only one reports a real count (`ahead=1`). The counts are the stale-branch gap, not worker commits, so:

- Every killed worker pushes its branch even when it made no commits, leaving remote branches with no unique work. Orphan and continuation logic then has to sort them out.
- The `ahead=` diagnostic is meaningless in that repo.
- In a repo whose default is `develop` with no `main` or `master` ref, both counts fail, `ahead_count` becomes 0 and the function returns early. The watchdog then kills the worker **without** pushing real WIP commits, defeating t2923's purpose (work preservation for the next dispatch).
- A worker left on the integration branch itself (`develop`) is not covered by the `main | master` skip, so its local commits are pushed directly to the integration branch, bypassing PR review.

The orphan handler already does this correctly (`.agents/scripts/headless-runtime-worker-orphan.sh:106-114` uses `_resolve_orphan_recovery_base_branch` → `aidevops_pr_base_branch`).

### Files Scope

- `.agents/scripts/worker-activity-watchdog.sh`

## How

- Source `shared-pr-base.sh` alongside `worker-lifecycle-common.sh` (guarded, as the file already does for `shared-repo-state-guard.sh`).
- In `_push_wip_before_kill`, resolve the base with `aidevops_pr_base_branch "${REPO_SLUG:-${DISPATCH_REPO_SLUG:-}}" "$work_dir"`, then count `origin/<base>..HEAD`. Only if that resolution fails or the ref is missing, fall back to `origin/HEAD`, then `origin/main`, then `origin/master`, using the first ref that exists.
- Skip the push when the current branch is the resolved base branch.
- Keep it best-effort and fail-open: never block the kill sequence. Keep the escape hatch and the detached/`main`/`master` skip. Add the resolved base to the log lines (`base=<ref>`) so the diagnostic is self-explaining.
- Do not change kill timing, sentinels or exit routing.

## Acceptance

- Disposable reproduction (not committed): a repo whose `origin/HEAD` → `develop` with a stale `origin/main` behind. A worker branch with 0 own commits must not push (no `[WATCHDOG_WIP_PUSH]` line). With 2 own commits it pushes with `ahead=2 base=origin/develop`. In a repo with only `origin/develop` and 1 own commit, it pushes (currently it does not). A worker on `develop` with a local commit does not push.
- Existing watchdog suites still pass: `bash .agents/scripts/tests/test-watchdog-no-false-kill.sh` and `bash .agents/scripts/tests/test-watchdog-hard-kill-continuous-output.sh`.
- `shellcheck .agents/scripts/worker-activity-watchdog.sh` reports no violations.

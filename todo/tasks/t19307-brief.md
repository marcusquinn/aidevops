# t19307: fix(pulse-dispatch): name the real cause when worktree pre-creation fails

Ref: GH#40000

## What

Make every `worktree pre-creation failed` pulse log line name the actual cause. `_dlw_precreate_helper_reason` in `.agents/scripts/pulse-dispatch-worker-launch.sh` must also recognise Git's lowercase `fatal:` / `error:` lines and the helper's own `Native worktree creation refused` and `Worktree retained:` lines. When no known pattern matches, it must fall back to the last non-empty output line instead of `none`.

## Why (evidence, one runner, pulse.log 2026-11-19..23)

- 16 `PRE_RUNTIME_FAILURE ... reason=worktree_precreation_failed` events. 12 of the 13 failure lines logged `helper_reason: 'none'`, and the only other text was `wt_helper stdout head`, cut at 120 characters: `Creating worktree with new branch '...' based on 'origin/develop'... Preparing worktree`. The decisive line (Git's `fatal:` or the helper's refusal) comes after that, so the log drops it.
- Example #33375 at 2026-11-23T11:53Z: `dispatch-stages.tsv` shows `precreate.git_worktree_add` ending after 783 ms with no `precreate.registry_register`. A concurrent `git worktree add` for #33422 was running in the same repository (23 s). This is consistent with Git lock contention, but the root cause cannot be confirmed because the error text is dropped.
- Each failure costs a won cross-runner claim, a pre-launch abort, zero-attempt evidence, and a retry next cycle. Without the cause, nobody can fix the underlying failure. Prior fixes (GH#35781, GH#36142, GH#38095) each started by adding exactly this kind of visibility.

## How

- EDIT: `.agents/scripts/pulse-dispatch-worker-launch.sh` `_dlw_precreate_helper_reason` (search `_dlw_precreate_helper_reason()`): keep the existing priority order (`managed-worktree:`, `Generation enrollment refused:`, `Cleanup-receipt reconciliation refused:`, `AIDEVOPS_WORKTREE_LIFECYCLE_DISPOSITION=|Error:`), then add `Native worktree creation refused|Worktree retained:` and `^(fatal|error):`, then fall back to the last non-empty line. Keep the output single-line and bounded to 200 characters.
- Callers are the precreate failure line and `MANAGED_ENROLLMENT_MISSING`; neither needs changes.

## Acceptance

- `shellcheck` clean on the edited file.
- Sourcing the function and feeding it the observed output plus a trailing `fatal: cannot lock ref ...` line prints the `fatal:` line; output containing only the two observed lines prints `Preparing worktree` rather than `none`; output with `Generation enrollment refused:` still prints that line.
- Existing `.agents/scripts/tests/test-precreation-failure-skip.sh` passes.

## Follow-up

Once failures name their cause, fix the underlying precreation failure (suspected concurrent `git worktree add` lock contention in one repository) under its own issue.

## Files Scope

- .agents/scripts/pulse-dispatch-worker-launch.sh

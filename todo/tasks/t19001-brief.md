<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Discovery pass: GH#37597 (merged) excluded the deferred-cleanup marker from the own-merged and PR-less completion proofs; GH#38059 (merged) did the same for reclaim. GH#38303 (merged) added the signal-less handoff path without that exclusion. No open issue covers it.
- [x] Tier: `tier:standard`. Reuses an existing, tested cleanliness helper; no new trust boundary.

## What

Make the GH#38303 signal-less own-PR handoff path (`_run_result_reconcile_signal_less_handoff`) treat a worktree whose only untracked path is the post-merge `.agents/.full-loop-cleanup-deferred` marker as clean, so a worker that merged its own closing PR through `full-loop-helper.sh merge` but omitted the completion token is routed through the post-PR handoff gate instead of `premature_exit`.

## Why

Evidence (last 72h, runner-local metrics `~/.aidevops/logs/headless-runtime-metrics.jsonl`): 16 issue-worker `premature_exit` outcomes. In 8, the issue was already CLOSED/COMPLETED 1.5-4 minutes before the worker exited. Two inspected cases (a Cloudron app repo and a WordPress plugin repo) follow the same sequence:

1. The worker opened its PR with `full-loop-helper.sh commit-and-pr --issue N` (exact `Resolves #N`, branch `feature/auto-*-ghN`).
2. `full-loop-helper.sh merge <PR>` merged it; the linked issue closed within 2 seconds; the runner stayed sole assignee.
3. The cleanup receipt was written as `FINALIZATION_PENDING` / `release_status: pending` (no worker release authority), so `_hrw_own_merged_terminal_complete` correctly declines (it requires a finalized receipt, GH#35629).
4. The final answer reported the merge but emitted no `FULL_LOOP_COMPLETE`, so `output_has_completion_signal` failed.
5. `_run_result_classify_incomplete_issue_exit` calls `_run_result_reconcile_signal_less_handoff`, which accepts `merged` handoff state, but its cleanliness test was raw `git status --porcelain`. After a helper merge the worktree always contains the untracked `.agents/.full-loop-cleanup-deferred` marker (`_merge_record_deferred_cleanup_owner`); in both surviving worker worktrees it was the only entry. The path returned 1, so the run became `premature_exit` (exit 77), mapped to `overwhelmed` for escalation (`_hrw_run_finish_crash_type`) and skipping `status:done` label normalization.

## How

- `.agents/scripts/headless-runtime-result.sh` `_run_result_reconcile_signal_less_handoff`: use `_hrw_task_worktree_status "$work_dir"` (the shared task-worktree status the own-merged and PR-less proofs use), guarded with `declare -F` so an unavailable helper still fails closed. Every other guard is unchanged.
- `.agents/scripts/tests/test-headless-runtime-completion-tests.sh`: `merged_marker` (marker only → `post_pr_handoff`) and `merged_marker_dirty` (marker plus another untracked file → `premature_exit`) scenarios in the GH#38303 fixture.

## Acceptance

- A signal-less issue worker with an exact-head merged own PR, runner-only assignee, closed issue and only the cleanup-deferred marker untracked is classified `post_pr_handoff` (`worker_pr_handoff_without_signal`, pattern `merged`), not `premature_exit`.
- Any other untracked or modified file still returns `premature_exit`.
- Existing completion and GH#38303 tests pass; ShellCheck clean.

## Files Scope

- .agents/scripts/headless-runtime-result.sh
- .agents/scripts/tests/test-headless-runtime-completion-tests.sh

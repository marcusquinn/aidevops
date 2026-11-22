## What

A stale-draft continuation worker that commits locally but exits before its single final push leaves the review worktree one or more commits **ahead** of the verified PR head. The next continuation dispatch treats that worktree as diverged and refuses to launch (`existing_review_worktree_diverged`, `retry_class=retryable_infrastructure`). The refusal repeats after every short cooldown, so the draft never moves and the linked issue stays blocked by its draft checkpoint. Every pulse round still spends a full dispatch ceremony on that issue before the draft-checkpoint block fires.

The continuation prompt already expects this case. `pr-checkpoint-continuation-helper.sh` tells the worker to save a recovery bundle after each commit and "on resume keep and verify unpushed local commits, never reset them away". But `_prrts_reconcile_existing_worktree_head` in `pr-review-thread-response-scanner-worktree.sh` only accepts a worktree that is behind the PR head (fast-forward). A worktree that contains the PR head plus unpushed commits fails the `merge-base --is-ancestor "$actual_head" "$head_oid"` check and is rejected as diverged.

Evidence from one runner on 2026-11-18:

- A draft PR in a private managed repository: the continuation worker launched at 18:58Z, committed one commit on top of the verified PR head at 19:25Z, and exited at 19:39Z with no push and no terminal-state command. Since 20:07Z every attempt logs `skipped — existing review worktree cannot fast-forward to verified PR head`. `git log` in the worktree shows exactly one commit ahead of the PR head, which is not diverged. An earlier draft in the same repository was in the same one-commit-ahead state and needed an interactive session to finish and merge it.
- `~/.aidevops/logs/pr-review-thread-response-scanner.log`: 833 `outcome=existing_review_worktree_diverged` outcomes in total, and 11 refusals across 6 PRs from 2026-11-15 to 2026-11-18.
- `~/.aidevops/logs/pulse.log`: the linked issue was re-attempted by the issue dispatcher at 371s, 40s and 70s of ceremony per attempt, each ending with `blocked:worker_draft_checkpoint_blocked`. Across the log, `worker_draft_checkpoint_blocked` and `stale_draft_checkpoint` attempts used about 22 hours of dispatch ceremony time over 5.7 days.

## How

- EDIT `.agents/scripts/pr-review-thread-response-scanner-worktree.sh`, `_prrts_reconcile_existing_worktree_head`: after the existing claim, dirty-state preservation, exact-head fetch and clean/branch re-check, add one case before the diverged refusal. When the dispatch is a checkpoint continuation (`_prrts_repair_linked_issue "$pr_number"` is non-empty) and `git merge-base --is-ancestor "$head_oid" "$actual_head"` holds, keep the worktree as it is, log how many unpushed commits are resumed, and return 0. The worker then starts with `AIDEVOPS_PR_REPAIR_HEAD_SHA` set to the verified remote head. Its exact-target fence and single fast-forward push still apply, and the prompt already says to keep the unpushed commits.
- Leave all other cases unchanged. A truly diverged worktree is still refused. Ordinary review-thread workers, whose prompt has no resume contract, are still refused. So are live or unverified owners and dirty state that cannot be preserved.

### Files Scope

- .agents/scripts/pr-review-thread-response-scanner-worktree.sh
- TODO.md

## Acceptance Criteria

- [ ] For a checkpoint continuation whose clean, exclusively claimed worktree is ahead of the verified PR head, dispatch launches the worker in that worktree without resetting it, and the log names the resumed commit count.
- [ ] A worktree whose HEAD neither contains nor is contained by the verified head is still refused with `existing_review_worktree_diverged`.
- [ ] An ordinary review-thread dispatch (no linked issue) with an ahead worktree is still refused.
- [ ] The existing worktree tests in `.agents/scripts/tests/test-pr-review-thread-response-scanner.sh` pass, and ShellCheck reports nothing on the edited file.

## Verification

- `bash .agents/scripts/tests/test-pr-review-thread-response-scanner.sh`
- `shellcheck .agents/scripts/pr-review-thread-response-scanner-worktree.sh`
- After deploy: the next continuation for the affected draft logs the resume line rather than `cannot fast-forward`, and new `existing_review_worktree_diverged` outcomes in `~/.aidevops/logs/pr-review-thread-response-scanner.log` are only true divergences.

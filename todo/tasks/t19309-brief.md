## What

A worker that fails before its runtime starts (any prelaunch cause, e.g. `project_node_environment_failure`) never publishes `CLAIM_RELEASED`. The issue stays assigned with `status:in-progress` until another runner's stale sweep resets it 12-30 minutes later, and after two such resets the t2008 stale-recovery escalation marks a healthy issue `status:blocked` + `needs-ai-recovery` and removes `auto-dispatch`.

## Why (evidence)

`_hrff_finalize_exit_trap` (`.agents/scripts/headless-runtime-failure.sh`) emits the worker runtime event first. Since GH#36553 that event posts the authenticated `DISPATCH_LEASE phase=terminal`. The claim release runs afterwards, and `_hrff_check_release_claim` evaluates `.agents/scripts/dispatch-release-claim.jq`, which (since GH#36593) returns `verdict:"terminal"` for any bound terminal lease after the claim, so the release is skipped as "no current unreleased matching dispatch claim". GH#36593 intentionally refuses a standalone release after a closed episode, so the release must come first; `headless-runtime-failure.sh` already documents that design at `_hrff_emit_release_terminal_lease` ("The later worker-event emission stays as a fallback and is a no-op once the lease is terminal").

Observed 2026-11-23 on a private downstream repository: one peer device failed 33/33 dispatches in ~4 s each (all before `phase=ready`). Every attempt posted only `DISPATCH_LEASE phase=terminal`, never `CLAIM_RELEASED`; the issue timelines show assignment and `status:in-progress` retained for 12, 15 and 30 minutes after each terminal lease, and five healthy issues were escalated to `status:blocked` within 30 minutes. The same runner's releases from other paths (`worker_complete`, `worker_ownership_lost`) were published normally.

## How

- EDIT: `.agents/scripts/headless-runtime-failure.sh` `_hrff_finalize_exit_trap` — run `_release_dispatch_claim` before the `_emit_worker_runtime_event` block, so `CLAIM_RELEASED` (with the prelaunch cause) publishes and projects lifecycle state first; the event's terminal lease remains the fallback.
- Reference pattern: `_hrw_finish_not_launched` in `.agents/scripts/headless-runtime-worker-finish.sh` already releases before marking the failed terminal state.
- Dedup stays correct: `dispatch-lease-claims.jq` treats a matching `CLAIM_RELEASED` as terminal (`attempt_id:"release"`), which `_dd_has_matching_terminal_lease` accepts for generation-marked dispatches.

### Files Scope

- .agents/scripts/headless-runtime-failure.sh

## Acceptance

- A prelaunch failure through the EXIT trap posts `CLAIM_RELEASED reason=<prelaunch cause>` and clears assignment/status without waiting for the stale sweep.
- Existing exit-trap and release tests pass: `.agents/scripts/tests/test-headless-runtime-contract-tests.sh`, `test-headless-runtime-release-unlock.sh`, `test-worker-exit-classifier.sh`, `test-headless-runtime-checkpoint-tests.sh`; ShellCheck clean.

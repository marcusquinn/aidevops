# t1686: GitHub comment-based optimistic locking for cross-machine dispatch dedup

**Session origin:** User reported multiple aidevops runners dispatching workers for the same issue
**Task ID:** t1686 | **Issue:** GH#6877
**Status:** in-progress | **Estimate:** ~2h

## What

Implement optimistic locking via GitHub issue comments to prevent multiple runners from dispatching workers for the same issue simultaneously. This closes the race window in the current `is_assigned` check where two runners can both read "unassigned" and both dispatch.

## Why

Current dedup guards (GH#4947) have a non-atomic read-then-write race:
1. Runner A checks `is_assigned` → unassigned
2. Runner B checks `is_assigned` → unassigned (A hasn't written yet)
3. Both assign themselves and dispatch → duplicate workers

Startup jitter (0-30s) reduces but doesn't eliminate collisions. The dispatch ledger is local-only. Process-based dedup only sees same-machine workers.

## How

New `dispatch-claim-helper.sh` implementing a claim protocol:
1. Post plain-text claim comment on the issue: `DISPATCH_CLAIM nonce=UUID runner=LOGIN ts=ISO`
2. Sleep consensus window (default 8s, configurable via `DISPATCH_CLAIM_WINDOW`)
3. Re-read issue comments, find all `DISPATCH_CLAIM` comments within the window
4. If this runner's claim is chronologically first → exit 0 (won, proceed)
5. If another runner's claim is older → exit 1 (lost, back off)
6. Clean up claim comments after dispatch completes or on loss

Integration: new `claim` subcommand in `dispatch-dedup-helper.sh`, updated dedup guard in `pulse.md`.

## Acceptance Criteria

- [ ] `dispatch-claim-helper.sh claim <issue> <slug>` returns exit 0 (won) or exit 1 (lost)
- [ ] `dispatch-claim-helper.sh release <issue> <slug>` cleans up claim comments
- [ ] Plain-text comments are visible in rendered GitHub issue view
- [ ] API failures fail-open (proceed with dispatch)
- [ ] Consensus window configurable via `DISPATCH_CLAIM_WINDOW` env var
- [ ] ShellCheck clean
- [ ] Tests pass

## Context

- Prior art: GH#4947 (assignee check + jitter), GH#6696 (dispatch ledger), GH#5662 (stale PID fix)
- Existing helpers: `dispatch-dedup-helper.sh`, `dispatch-ledger-helper.sh`, `pulse-wrapper.sh`
- Pulse dedup guard sequence: pulse.md step 4

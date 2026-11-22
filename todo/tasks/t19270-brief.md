## Origin

Interactive productivity mining (pulse/worker throughput mission). Found while tracing why `marcusquinn/aidevops#39773` stayed `status:available`, unassigned and undispatchable for ~2 hours after a peer runner's worker crashed during startup.

## What

Bind the launch-recovery `CLAIM_RELEASED` to the exact dispatch claim generation on the `status:queued` recovery path, so peer runners retire the dispatch-comment lock immediately instead of waiting out the 7200s active-worker window.

## Why

`recover_failed_launch_state` (`.agents/scripts/pulse-cleanup.sh`) only resolves `claim_id` + `nonce` through `_launch_recovery_owns_registered_attempt`, which runs only for `status:in-progress` issues. A worker that dies during startup leaves the issue `status:queued`, so the release is posted unbound (`CLAIM_RELEASED reason=launch_recovery:<reason> runner=<login> ts=...`).

The dispatch comment carries an `aidevops:dispatch lease_token=... claim_id=...` marker. `has_dispatch_comment` (`.agents/scripts/dispatch-dedup-helper.sh`) correctly refuses to let unbound prose retire a marked generation (trust boundary in `_dd_has_trusted_completion_after_dispatch`), and `_dd_has_matching_terminal_lease` only accepts a release carrying the claim id and nonce. Result: every runner treats the crashed attempt as a live worker for up to `DISPATCH_ACTIVE_WORKER_MAX_AGE` (7200s).

Evidence (2026-11-15..22, one private managed repo plus `marcusquinn/aidevops`): 35 launch-recovery releases; 15 were unbound while a lease-marked dispatch comment was current (8 `no_worker_process`, 7 `crash_during_startup`). The `no_worker_process` cooldown marker already limits redispatch to 1800s by design, so the excess stall is ~90-120 min per event, ~20-30 issue-hours per week. Live example: #39773 dispatch comment 23:43:00Z, unbound release 23:43:37Z, dedup still blocking at ~23:59Z with 6236s remaining.

## Tier

`tier:standard` — single-function addition in a dispatch-path script with an established binding pattern to mirror.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-cleanup.sh` — add `_launch_recovery_bind_ledger_claim` and call it from `recover_failed_launch_state` when no binding was resolved.

### Implementation Steps

1. Add `_launch_recovery_bind_ledger_claim issue repo ledger_entry self_login`: read `lease_token`, `runner_device`, `session_key` from the captured ledger entry; return 1 if any is empty.
2. Fetch issue comments (paginated, standalone jq per GH#38185) and select the latest trusted (`OWNER`/`MEMBER`/`COLLABORATOR`) self-authored `DISPATCH_CLAIM nonce=` comment whose `lease_token=`, `device=` and `session=` fields exactly equal the ledger values. Set `_LAUNCH_RECOVERY_CLAIM_ID` / `_LAUNCH_RECOVERY_CLAIM_NONCE` from its id and nonce.
3. In `recover_failed_launch_state`, after `_verify_launch_recovery_state` succeeds and before `_record_released_launch_failure`, call the helper only when `_LAUNCH_RECOVERY_CLAIM_ID` is empty; failure keeps today's unbound release.

### Hazards and Compatibility

- Trust boundary: only this runner's own generation, matched by the unguessable ledger lease token plus device and session. Never bind to another login, device or session. Mark the filter `#aidevops:trust-boundary`.
- The in-progress ownership proof (`_launch_recovery_owns_registered_attempt`) stays unchanged.
- A missing or incomplete ledger entry falls back to the existing unbound release.

### Files Scope

- `.agents/scripts/pulse-cleanup.sh`

## Acceptance Criteria

- A queued launch failure whose ledger entry matches a self-authored `DISPATCH_CLAIM` posts `CLAIM_RELEASED ... claim_id=<id> nonce=<nonce>`.
- `dispatch-dedup-helper.sh has_dispatch_comment` on that comment stream returns 1 (dispatch allowed) after the bound release.
- No binding when lease token, device, session, author or trust association differ.
- Existing suites pass: `test-post-launch-in-progress-recovery.sh`, `test-no-worker-process-fix.sh`, `test-dispatch-dedup-helper-is-assigned.sh`; ShellCheck clean.

## Relevant Files

- `.agents/scripts/pulse-cleanup.sh:395` — `_post_launch_recovery_claim_released` (already accepts claim id + nonce)
- `.agents/scripts/pulse-cleanup.sh:567` — `_launch_recovery_owns_registered_attempt` (in-progress binding pattern)
- `.agents/scripts/dispatch-lease-claims.jq:72` — bound `CLAIM_RELEASED` terminal transition
- `.agents/scripts/dispatch-dedup-helper.sh:887` — `_dd_has_matching_terminal_lease`

## What

Queue a held first observation of a retry-only terminal-blocker class (`permission_required`) for this runner's recovery owner at release time, the same way revision-re-armed classes are queued.

## Why

`_hrff_enqueue_observation_recovery` in `.agents/scripts/headless-runtime-failure.sh` (lines 668-677) gates intake on `terminal_blocker_rearms_on_revision`. The retry-only classes from GH#35925 (`permission_required`, `push_policy_timeout`, `network_policy_timeout`) fail that check, so the releasing runner never queues them. Their only intake is the cross-repo seed (`tbr_seed`, `_tbr_seed_reason`), which already accepts them through `terminal_blocker_observation_recoverable`. The seed runs within an 8-second stage cap inside the 3-hourly `pending` call. On one maintainer runner it has not completed a full pass since 2026-10-20 (`last_seed_epoch`).

As a result, an OWNER/MEMBER `terminal-blocker-circuit:retry` on a `permission_required` first observation does not take effect. GH#36026 / PR #36042 adds a 10-minute mechanical `rearm` pass, but that pass walks queued entries only and skips the seed, so it cannot release an entry that was never queued.

Observed on 2026-10-30 in a managed private repo: three issues released as `permission_required` first observations (no circuit) at 03:13-03:23Z received standalone OWNER retry directives at 04:05Z. They were still `status:blocked` at 05:27Z and absent from the runner's recovery queue. A manual `terminal-blocker-recovery-helper.sh enqueue` followed by `pending` produced `rearm_decision ... reason=trusted_retry` for all three and released them with receipts. In an earlier case, a revision-class observation queued by its releasing runner re-armed 8h39m after its retry, through the 3-hour `pending` cadence that GH#36026 addresses.

## How

### Files to modify

- EDIT: `.agents/scripts/headless-runtime-failure.sh`: in `_hrff_enqueue_observation_recovery`, gate on `terminal_blocker_observation_recoverable` (revision or retry-only, defined in `.agents/scripts/terminal-blocker-circuit.sh:567`) instead of `terminal_blocker_rearms_on_revision`, and update the function comment to say retry-only classes are queued too (GH#35925). Keep `_hrff_blocked_exit_holds` and the persisted-fragment guard unchanged.
- EDIT: `.agents/scripts/tests/test-terminal-blocker-circuit.sh`: in `test_retry_only_observation_recovery`, assert that `_hrff_enqueue_observation_recovery` queues `permission_required` (stub `_hrff_enqueue_blocker_recovery` with a counter, as `test_unknown_hold_rearms_on_trusted_retry` does at lines 1006 and 1017-1019).

### Out of scope

- The `push_policy_timeout` / `network_policy_timeout` release path calls `_hrff_enqueue_observation_recovery` only when `reason == blocked` (`headless-runtime-failure.sh:819`). Those releases can project `status:available` when no draft exists (lines 945-952), so widening that call site needs separate evidence. Not changed here.
- The seed's completion rate and GH#36026's interval are not changed.

### Reference pattern

- `_tbr_seed_reason` in `.agents/scripts/terminal-blocker-recovery-helper.sh` already uses `terminal_blocker_observation_recoverable` for the same decision.

## Acceptance

1. A `permission_required` first observation that holds `status:blocked` is enqueued by the releasing runner; a `runner_capability_unmet` release is still never enqueued.
2. A later trusted retry releases it on the next `pending` pass (and on the GH#36026 `rearm` pass once merged) without a manual enqueue.
3. ShellCheck clean; `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh` passes.

## Verification

- `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh`
- `shellcheck .agents/scripts/headless-runtime-failure.sh .agents/scripts/tests/test-terminal-blocker-circuit.sh`

### Files Scope

- `.agents/scripts/headless-runtime-failure.sh`
- `.agents/scripts/tests/test-terminal-blocker-circuit.sh`

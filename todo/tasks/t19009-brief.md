<!-- aidevops:brief-schema=v2 -->

# fix(checkpoints): a failed continuation launch must not turn a stalled draft into a permanent maintainer hold

## Pre-flight

- [x] Memory recall: `checkpoint continuation worker_not_launched stall release blocked attention` → 0 hits — no relevant lessons
- [x] Discovery pass: 35 commits touch `pr-checkpoint-continuation-helper.sh` since GH#36525; 0 open PRs; related merged GH#38103 (never-launched episodes closed by a terminal lease) and GH#37669 (approval reuse after `worker_not_launched`). Adjacent open issue #38355 (fleet-window timing) changes `_pcc_fleet_rearm_allowed`, not release classification.
- [x] File refs verified: 6 refs checked, all present at HEAD `4113fe2d5c`
- [x] Tier: `tier:standard` — known pattern (GH#36597, GH#38103) inside a decided boundary
- [x] Seeded draft PR decision recorded: skipped — implemented directly in the filing interactive session

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (productivity mission session)
- **Conversation context:** Mining open `BLOCKED_CHECKPOINT_ATTENTION` issues for work that waits on a human without need.

## What

When a Pulse exact-head continuation of a stall-released worker draft fails to launch, the runtime releases the claim as `CLAIM_RELEASED reason=worker_not_launched`. `_pcc_stall_release_evidence` then finds no current stall release, `blocked-attention` posts `BLOCKED_CHECKPOINT_ATTENTION ... reason=worker_not_launched`, and the draft is held until a maintainer acts. Nothing re-arms it.

After this fix, a `worker_not_launched` release keeps the draft on the bounded automatic continuation path:

1. A never-launched continuation episode of the PR's own session (claim and prelaunch leases, no ready lease, no `Dispatching worker`) that is closed by its own `CLAIM_RELEASED reason=worker_not_launched` stays transparent, as GH#38103 already does for episodes closed only by a terminal lease. The earlier stall release stays current evidence. The first failed launch is retried at once; the second reaches the existing per-head attention and re-arm windows.
2. A `worker_not_launched` release whose episode did post a ready lease (runtime never confirmed, `_hrff_verified_release_reason`) is a stall-class release under `_PCC_STALL_RELEASE_PATTERN`. It is bounded by the existing per-head stall count, re-arm windows, per-PR fuse and the GH#37779 terminal action, never by a human-only attention record.

## Why

Sample on 2026-11-14 of 38 open issues carrying `BLOCKED_CHECKPOINT_ATTENTION` across the managed fleet: 10 (26%) were held only because the newest release was `worker_not_launched`. They had been idle 2-23 hours, with no re-arm path. Examples:

- This repo: #38282 (draft #38284). Stall release `worker_draft_checkpoint` at 13:41Z. Continuation claim at 13:44Z, prelaunch lease, then `CLAIM_RELEASED reason=worker_not_launched` at 13:45Z in session `pr-checkpoint-continuation-marcusquinn-aidevops-38284`, and `BLOCKED_CHECKPOINT_ATTENTION ... reason=worker_not_launched` at 13:47Z. Nothing since.
- One managed product repo, local runner logs: `STALLED_CHECKPOINT_REARMED ... mode=untried_runner`, then `headless-prelaunch.log` `prelaunch_abort ... stage=post_attempt_observers_start cause=worker_runtime_not_invoked`, then on every later cycle `STALLED_CHECKPOINT_CONTINUATION_SKIPPED: ... has no current stall release` and `DISPATCH_BLOCK_REASON reason=worker_draft_checkpoint_blocked`.

A launch failure records no worker decision and leaves the head unchanged. GH#36597 already treats `worker_noop_zero_output` and `worker_incomplete_exit` the same way. Sending it to a human contradicts the release fragment that the runtime itself posts ("bounded retries").

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Two small edits to an existing jq classification, following GH#36597 (pattern addition) and GH#38103 (transparent never-launched episode). Recovery bounds are unchanged.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pr-checkpoint-continuation-helper.sh:59-74`: add `worker_not_launched` to `_PCC_STALL_RELEASE_PATTERN` and its comment.
- `EDIT: .agents/scripts/pr-checkpoint-continuation-helper.sh:1348-1360`: `_PCC_JQ_LAUNCH_DEFS` `unlaunched_episode` also accepts the same session's `CLAIM_RELEASED reason=worker_not_launched` line.
- `EDIT: .agents/scripts/pr-checkpoint-continuation-helper.sh:1428-1453`: stall counts (`count_since`, per-PR `$releases`) skip comments in a transparent unlaunched episode, so `$failed_launches` alone counts them (no double count).
- `EDIT: .agents/scripts/tests/test-pr-checkpoint-continuation-attention.sh:229-259`: extend the GH#38103 fixture with the release-closed shape and the ready-lease shape.
- `EDIT: .agents/scripts/pulse-draft-checkpoint-unblock.sh:48`: keep `_PDCU_RELEASE_REASON_PATTERN` in parity (its test compares it with the continuation pattern).
- `EDIT: .agents/scripts/tests/test-pulse-draft-checkpoint-unblock.sh:618-629`: the parity test also strips the synthesized `orphaned_terminal_lease` (GH#38236 broke it on main; no CLAIM_RELEASED carries that reason).
- `EDIT: .agents/reference/checkpoint-revision-recovery.md:81-87`: name `worker_not_launched` among continuation-eligible reasons.

### Complete Write Surface

- **Callers/readers:** `_pcc_dispatch_stalled` (`:1888`) and `_pcc_completed_release_evidence` (`:1082`, uses `_PCC_STALL_RELEASE_PATTERN` to exclude stall reasons from blocked attention). Called from `pulse-dispatch-dedup-layers.sh:522-562`.
- **Writers/mutation paths:** `worker_not_launched` releases come from `pr-checkpoint-compensation.sh:74` and `headless-runtime-failure.sh:810-831`. Not changed.
- **Existing verification/tests:** `test-pr-checkpoint-continuation-helper.sh` sources the attention module. The python approval validators (`pr_checkpoint_events.py` `STALL_RELEASE_REASONS`, `pr_checkpoint_reuse.py`) are a separate approval contract and are not changed.
- **Schemas/config:** N/A because `rg -n 'AIDEVOPS_PCC_' .agents/scripts/pr-checkpoint-continuation-helper.sh` shows the bounds already exist and no key is added.
- **Generated/deployed mirrors:** deployed copy under `~/.aidevops/agents/scripts/` via `setup.sh` after release.
- **Migrations/backfills:** N/A because the held drafts are re-evaluated by `_pcc_dispatch_stalled` on the next dispatch cycle. An existing blocked attention record for the head counts as posted (alt key in `_pcc_stall_release_evidence`), so no duplicate record is written.
- **Cleanup/rollback paths:** revert the commit; `_PCC_STALL_RELEASE_PATTERN` and `_PCC_JQ_LAUNCH_DEFS` return to their previous values.

### Implementation Steps

1. Pattern: insert `worker_not_launched` after `worker_incomplete_exit` in `_PCC_STALL_RELEASE_PATTERN`. Comment: a launch failure records no worker decision and leaves the head unchanged.
2. `unlaunched_episode`: `launch_lines` items may also be a `CLAIM_RELEASED reason=worker_not_launched` line. Keep `in_session` and `(ready_event | not)` for every line, and keep `launched_after` unchanged. A release line is transparent only when its whole episode (from the in-session claim it closes, via `episode_start`) had no ready lease or `Dispatching worker`; `launched_after` alone looks forward and would miss a ready lease before the release.
3. Counts: in `count_since` and the `$releases` selector add `(unlaunched_episode($c) | not)`.
4. Tests: release-closed episode (1 → stalls 1 on the prior `worker_draft_checkpoint`; 2 → stalls 2). Ready-lease episode → release is current evidence with reason `worker_not_launched`. `_pcc_completed_release_evidence` posts no blocked attention for `worker_not_launched`.
5. Run `bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh` and `shellcheck` on the edited files.

### Hazards and Compatibility

- **Concurrency/atomicity:** unchanged. The continuation still needs the fenced distributed claim.
- **Migration/rollback:** none; classification only.
- **Mixed-version/backward compatibility:** older runners keep posting blocked attention for these heads. Upgraded runners continue them. The alt-key dedup stops a second record.
- **Idempotency/retry:** repeated launch failures are bounded. In-session: the first is free, then the per-head fuse applies. Ready-lease shape: counted as a stall. Both reach re-arm windows and the per-PR fuse with its terminal action.
- **Partial failure/recovery:** a launch that fails again releases as before; nothing new is written by this change.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh
shellcheck .agents/scripts/pr-checkpoint-continuation-helper.sh .agents/scripts/tests/test-pr-checkpoint-continuation-attention.sh
```

- **Surface mapping:** the parent suite exercises `_pcc_stall_release_evidence` (both episode shapes and the stall counts) and `_pcc_completed_release_evidence` (blocked-attention exclusion) through the GH#38103 fixtures; ShellCheck covers both edited shell files.

### Files Scope

- `.agents/scripts/pr-checkpoint-continuation-helper.sh`
- `.agents/scripts/tests/test-pr-checkpoint-continuation-attention.sh`
- `.agents/reference/checkpoint-revision-recovery.md`

## Acceptance Criteria

- [ ] Pulse continues a stall-released draft after its continuation ended `CLAIM_RELEASED reason=worker_not_launched` in the PR's own session: `_pcc_stall_release_evidence` returns the earlier stall release, with stalls 1 after one failed launch and 2 after two.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh"
  ```

- [ ] A `worker_not_launched` release is never routed to `BLOCKED_CHECKPOINT_ATTENTION` (`_pcc_completed_release_evidence` rejects it), and edited or foreign-session episodes still fence the stall release.

  ```yaml
  verify:
    method: codebase
    pattern: "worker_incomplete_exit\\|worker_not_launched"
    path: ".agents/scripts/pr-checkpoint-continuation-helper.sh"
  ```

## Context & Decisions

- Reuses the existing bounds instead of adding a new retry counter, so the recovery machinery does not grow.
- The python approval validator (`STALL_RELEASE_REASONS`) is left alone. GH#37669 already covers approval reuse after `worker_not_launched`. Making the release itself approvable is a separate contract.
- The cause of `worker_runtime_not_invoked` at `post_attempt_observers_start` is a separate launch-reliability question. This fix removes the human dependency whatever the cause.

## Relevant Files

- `.agents/scripts/pr-checkpoint-continuation-helper.sh:74` — stall pattern
- `.agents/scripts/pr-checkpoint-continuation-helper.sh:1348-1360` — `_PCC_JQ_LAUNCH_DEFS`
- `.agents/scripts/pr-checkpoint-continuation-helper.sh:1397-1497` — `_pcc_stall_release_evidence`
- `.agents/scripts/tests/test-pr-checkpoint-continuation-attention.sh:229-259` — GH#38103 fixture to extend

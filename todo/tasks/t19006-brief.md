<!-- aidevops:brief-schema=v2 -->

# t19006: perf(dispatch): halve launch ceremony and dedup verdict time

**Parent task:** t19002 (GH#38332, phase 3 "reduce launch ceremony") — see [todo/tasks/t19002-brief.md]

## Pre-flight (auto-populated by briefing workflow)

- [x] Discovery: per-stage timing already exists (`dispatch-stage-instrument.sh`, GH#38101 layer-4 steps, GH#38180 layer-6 sub-gates, `_dch_timed` in `dispatch-claim-runtime.sh`). This task uses that data and adds no new instrumentation framework.
- [x] Related merged work: GH#38237 and GH#38261 (negative-cache reuse), GH#38272 (token-spend cache), GH#38163 (shared open-PR evidence). None removes the repeated assignment checks or the precreate verification cost measured below.

## Origin

- Created: 2026-11-14, interactive productivity-mission session (OpenCode), author ai-interactive.
- Evidence: one runner's `~/.aidevops/logs/dispatch-stages.tsv` and `pulse.log`, 2026-11-13T03:00Z to 2026-11-14T21:30Z (about 42h).

## What

Cut dispatch wall-clock cost, keeping every ownership and safety invariant:

1. Successful launch: median `dedup.ceremony_total` from **349s to 175s or less**.
2. Every candidate: average `dedup.dedup_check` from **69s to 35s or less**.

An interactive full-loop session starts work in seconds. A worker spends about 6 minutes in ceremony before its model starts, and blocked candidates spend about a minute each just to reach "blocked". Those minutes come from the same 5 parallel dispatch slots that launch real work.

## Why

Measured slot time over 42h (`dispatch-stages.tsv`, completed rows):

| Stage | n | avg | total |
|---|---|---|---|
| `dedup.ceremony_total` (launch path) | 131 | 349s | 762 min |
| `dedup.worker_launch_total` | 131 | 199s | 435 min |
| `dedup.dedup_check` (every candidate) | 890 | 69s | 1026 min |
| `dedup.layer4_pr_evidence` | 858 | 22s | 314 min |
| `dedup.layer6_assignee` | 374 | 28s | 172 min |
| `dedup.claim_consensus` | 149 | 62s | 154 min |
| `dedup.precreate_worktree` | 108 | 74s | 133 min |
| `precreate.helper_add` | 95 | 72s | 113 min |
| `dedup.layer4.stalled_checkpoint` | 125 | 37s | 77 min |

All `dedup.*` rows total about 4,961 slot-minutes in 42h, roughly two of five slots busy full-time on ceremony.

`claim_consensus` breakdown (`[dispatch-claim] stage=` lines in `pulse.log`): `assignment_guard` 17.2s plus `final_assignment_guard` 16.2s, `consensus_window` 8.1s (the configured `DISPATCH_CLAIM_WINDOW`), `claim_comments` 3.6s x2, `claim_post` 4.3s. Layer 6 (`dedup.layer6_assignee`, 28s) runs the same `dispatch-dedup-helper.sh is-assigned` check shortly before, so each launch pays about 61s for three assignment checks.

Benign blocks by reason (`Dispatch_max ... elapsed_ms`): `worker_draft_checkpoint_blocked` n=136 avg 143s (324 min), `stale_draft_checkpoint` n=82 avg 102s (140 min), `dedup_active_claim` n=107 avg 57s, `dedup_pr_evidence` n=103 avg 48s. One draft-checkpoint candidate took 194s to reach a verdict that had not changed in 3 days.

## Tier

**Selected tier:** `tier:thinking`

Several hot paths each carry a safety invariant; the worker must decide which evidence can be reused safely.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/dispatch-claim-helper.sh:760-830` — `assignment_guard` / `final_assignment_guard`: reuse layer-6 evidence or call a cheaper check; keep the post-consensus guard fresh.
- `EDIT: .agents/scripts/dispatch-claim-runtime.sh:54-72` — share the validated per-launch snapshot (`_dch_snapshot_valid`) with the assignment check.
- `EDIT: .agents/scripts/dispatch-dedup-helper.sh:1390-1460` — `is-assigned` / `is-assigned-read-only`: profile and cut redundant network reads.
- `EDIT: .agents/scripts/pulse-dispatch-dedup-layers.sh:326-390` — layer 4: consult the negative cache before the checkpoint continuation helpers.
- `EDIT: .agents/scripts/pulse-dispatch-dedup-layers.sh:693-730` — layer 6: export its verdict and fingerprint for the claim step.
- `EDIT: .agents/scripts/pulse-dispatch-lib.sh:459-515` — `_dispatch_negative_cache_record`: log silent record skips once per issue with their reason.
- `EDIT: .agents/scripts/worktree-helper-add.sh` — bound `verify.reconcile` / `reconcile_scan` for a freshly created worker worktree.
- `EDIT: .agents/scripts/pulse-dispatch-worker-launch.sh:1937-2036` — `_dispatch_launch_worker`: attribute `worker_launch_total` beyond precreate (the `_ds_record` stage calls) if the targets are not met. Precreate itself is `_dlw_precreate_worktree` at `pulse-dispatch-worker-launch.sh:885-986`.

### Complete Write Surface

- **Callers/readers:** `pulse-dispatch-core.sh` (`dispatch_with_dedup`) calls the dedup layers. `dispatch-claim-helper.sh` is invoked from `pulse-dispatch-dedup-layers.sh` (claim step around line 787) and `dispatch-single-issue-helper.sh`. `worktree-helper-add.sh` is called by `pulse-dispatch-worker-launch.sh` precreate. Negative-cache readers are `_dispatch_negative_cache_reason` callers in `pulse-dispatch-lib-candidates.sh`.
- **Writers/mutation paths:** claim comments (`claim_post`) and handoff leases in `dispatch-claim-helper.sh`; negative-cache files under `~/.aidevops/logs/dispatch-negative-cache/` written by `_dispatch_negative_cache_record`; stage rows appended to `~/.aidevops/logs/dispatch-stages.tsv` by `dispatch-stage-instrument.sh`. No GitHub write paths are added.
- **Existing verification/tests:** `.agents/scripts/tests/test-dispatch-claim-helper.sh`, `.agents/scripts/tests/test-pulse-stale-pr-continuation.sh`, `.agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh`. Production evidence: `dispatch-stages.tsv` and `[dispatch-claim] stage=` lines in `pulse.log`.
- **Schemas/config:** the negative-cache record format is the tab-separated line in `_dispatch_negative_cache_record` (line 504). Keep the field order; add no fields unless every reader is updated in the same PR. `DISPATCH_CLAIM_WINDOW` stays at its default.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`. There is no generated output; deployment follows the normal release.
- **Migrations/backfills:** N/A. Existing negative-cache files stay readable because the format is unchanged; old records expire through their existing TTL and boundary.
- **Cleanup/rollback paths:** revert the PR. Cached verdicts in `~/.aidevops/logs/dispatch-negative-cache/` self-invalidate on fingerprint change, and no persistent state outside that directory is introduced.

### Implementation Steps

1. Read `[dispatch-claim] stage=` lines and `dispatch-stages.tsv` for the latest 12h to confirm the baseline (commands under Verification Before Dispatch).
2. Profile one `dispatch-dedup-helper.sh is-assigned` call (e.g. `bash -x` or its existing stage output) and list its network reads. Decide between making it cheap (one issue read and one comments read, shared through the validated claim snapshot) and reusing the layer-6 verdict for `assignment_guard` when issue `updated_at` and the comment count are unchanged. The final post-consensus guard must stay a fresh read.
3. In `worktree-helper-add.sh`, skip or bound `verify.reconcile` / `reconcile_scan` when the worktree was created by this call and its generation marker was just written. Keep the full check for reused or recovered worktrees.
4. In layer 4, check `_dispatch_negative_cache_reason` for `worker_draft_checkpoint_blocked` / `stale_draft_checkpoint` before invoking the continuation helper. In `_dispatch_negative_cache_record`, log `negative_cache_record_skipped reason=<boundary|fingerprint> issue=#N` when `_dispatch_draft_hint_boundary` or `_dispatch_negative_pr_fingerprint` fails, and fix the failing input found on a real skipped issue.
5. If the targets are still missed, attribute `worker_launch_total` stages in `pulse-dispatch-worker-launch.sh` and cut the next largest step.
6. Run ShellCheck and the existing tests, commit a WIP checkpoint, then measure again after deployment.

### Hazards and Compatibility

- **Concurrency/atomicity:** cross-runner double dispatch is the main risk. The consensus window, claim lock and fresh post-consensus assignment guard stay. Only the pre-consensus duplicate check may reuse evidence, and only when the issue revision is unchanged.
- **Migration/rollback:** no data migration. Rollback is a revert; caches self-invalidate on fingerprint change.
- **Mixed-version/backward compatibility:** other runners on older versions still post the same claim comments and read the same negative-cache format. Claim comment formats must not change.
- **Idempotency/retry:** a reused verdict is a hint; any mismatch falls through to the full check. Retrying a dispatch after a cache miss behaves as today.
- **Partial failure/recovery:** a failed cache read or write falls through to the authoritative ceremony, as today. A precreate verification skipped on a fresh worktree must leave the full check in place for any reused path.

### Complexity Impact

`_dedup_layer6_assignee_and_stale` and the claim functions are near the 100-line function gate. Extract helpers before adding logic; keep each changed function under 80 lines.

### Verification Before Dispatch

```bash
awk -F'\t' '$6=="complete" && $4 ~ /^dedup\.(ceremony_total|dedup_check)$/ {n[$4]++; s[$4]+=$5} END{for(k in n) printf "%s n=%d avg=%.0fms\n", k, n[k], s[k]/n[k]}' ~/.aidevops/logs/dispatch-stages.tsv
rg -o '\[dispatch-claim\] stage=[a-z_]+ elapsed_s=[0-9]+' ~/.aidevops/logs/pulse.log | sort | uniq -c | sort -rn | head
bash .agents/scripts/tests/test-dispatch-claim-helper.sh
bash .agents/scripts/tests/test-pulse-stale-pr-continuation.sh
bash .agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh
shellcheck .agents/scripts/dispatch-claim-helper.sh .agents/scripts/dispatch-claim-runtime.sh .agents/scripts/pulse-dispatch-dedup-layers.sh .agents/scripts/pulse-dispatch-lib.sh .agents/scripts/worktree-helper-add.sh
```

- **Surface mapping:** the `awk` command proves both timing targets (acceptance 1). The `rg` command proves the assignment-guard reduction (acceptance 2). `test-dispatch-claim-helper.sh` covers claim consensus and the final guard (concurrency hazard, acceptance 4). `test-pulse-stale-pr-continuation.sh` and `test-dispatch-candidate-failure-reasons.sh` cover negative-cache reuse and draft-checkpoint holds (acceptance 3 and 4). `shellcheck` covers every touched script.
- **Broad verification trigger:** Not required. The changes are confined to dispatch helpers with focused tests.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: the three test scripts above
- [ ] WIP commit created before broad gates: `wip: t19006 dispatch ceremony`
- [ ] Evidence-triggered broad verification then run: not required — confined to dispatch helpers

### Scope Boundaries

**Hard boundaries:** do not remove the consensus window, claim lock, NMR gate, fresh final assignment guard or draft-checkpoint redispatch hold. Do not change claim comment formats.

**AI brief owner:** the interactive maintainer session that filed GH#38332.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/dispatch-claim-helper.sh`
- `.agents/scripts/dispatch-claim-runtime.sh`
- `.agents/scripts/dispatch-dedup-helper.sh`
- `.agents/scripts/pulse-dispatch-dedup-layers.sh`
- `.agents/scripts/pulse-dispatch-lib.sh`
- `.agents/scripts/pulse-dispatch-worker-launch.sh`
- `.agents/scripts/worktree-helper-add.sh`
- `.agents/scripts/tests/test-dispatch-claim-helper.sh`
- `.agents/scripts/tests/test-pulse-stale-pr-continuation.sh`
- `.agents/scripts/tests/test-dispatch-candidate-failure-reasons.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] Positive: over a 12h window after deployment, `dispatch-stages.tsv` shows median `dedup.ceremony_total` of 175s or less and average `dedup.dedup_check` of 35s or less. The PR reports before and after numbers.
- [ ] Positive: `[dispatch-claim] stage=assignment_guard` averages under 5s, or the stage is removed with the reuse rationale documented. The post-consensus `final_assignment_guard` still performs a fresh read.
- [ ] Positive: a draft-checkpoint verdict whose PR head, labels and issue comments are unchanged is answered from the negative cache, `worker_draft_checkpoint_blocked` averages under 30s, and a skipped cache record is logged with its reason.
- [ ] Negative: no cross-runner double dispatch. The consensus window, claim lock, NMR gate and draft-checkpoint redispatch hold behave as before, and the existing tests above pass unchanged.

## Context & Decisions

- Non-goal: removing multi-runner coordination. The 8s consensus window is a small share of the cost and protects against cross-runner double dispatch.
- Non-goal: new test harnesses. Use production timing data and existing tests.
- If a safety check cannot be made cheaper without weakening it, keep it and record why in the PR. The targets are goals, not licence to drop invariants.

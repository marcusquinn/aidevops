<!-- aidevops:brief-schema=v2 -->

# fix(pulse): stop every worker launch scanning the whole temp root with du before model selection

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `pulse dispatch launch gap du temp root todo-sync sweep worker log setup` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open or recently merged PRs on the target files; the per-launch sweep and its `du` arrived together in GH#28860 (#28928, 2026-07-30)
- [x] File refs verified at origin/main 141140ee22: `_ptsw_effective_recovery_cap` (`.agents/scripts/pulse-todo-sync-workspace.sh:436`), `aidevops_pulse_tmp_cleanup` (`.agents/scripts/pulse-temp-helper.sh:57`), `_dlw_setup_worker_log` (`.agents/scripts/pulse-dispatch-worker-launch.sh:237`), `_dlw_prebootstrap_gates` (`.agents/scripts/pulse-dispatch-worker-gates.sh:488`) and the orchestrator `_dispatch_launch_worker` (`.agents/scripts/pulse-dispatch-worker-launch.sh:1849`)
- [x] Tier: `tier:standard` — one function made lazy, one timed wrapper, two test-harness lines
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Pulse throughput investigation. Dispatch attempts lost minutes between the eligibility gate and model selection, a window with no stage records, and some of them then hit the 600s per-candidate timeout.

## What

Worker launch no longer runs a full-tree `du` of the shared temp root when the result cannot change the TODO-sync recovery cap, and the pre-model launch window (worker log setup and pre-bootstrap gates) writes entry and completion stage records.

## Why

- Every launch calls `_dlw_setup_worker_log` → `aidevops_pulse_tmp_cleanup` → `_ptsw_sweep_stale_workspaces` → `_ptsw_effective_recovery_cap`, which always ran `du -sk` over `~/.aidevops/.agent-workspace/tmp`.
- That `du` result matters only when TODO-sync candidates exceed the configured cap (default 50) but stay below the count threshold (default 50). With the defaults it can never change the cap. This runner had 1 TODO-sync workspace.
- The temp root on this runner holds about 39 GiB and 30,687 top-level entries. `du -sk` took 41.2s, then 35.8s (12.2s system) at load average 130. The live `_ptsw_effective_recovery_cap` call measured 32s on the base code and 0s with this change, with the same cap (50).
- `dispatch-stages.tsv` (80 attempts since 2026-10-10): the untimed gap between `eligibility_gate` completion and `resolve_tier_model` start was p50 64.9s, p90 255.9s, max 405.5s. During 18:39–18:48Z on 2026-10-11 six attempts spent 276–406s there while the wave ran 6 candidates in parallel, each with its own `du`. At least two of them then hit the 600s per-candidate timeout (`rc=124`, `reason=launch_error`) after reaching the canary.
- The dependency check in the same window is not the cost: the same issues' `dedup.blocked_by` stage (same `is_blocked_by_unresolved` call) took 1.4–6.2s, once 20.4s.
- The window had no stage records, so a timeout kill left no evidence of where the time went.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** a behaviour-preserving short-circuit in one function plus a timed wrapper around two existing calls. Dispatch-path module, so every gate keeps its order and return codes.

## How

### Files to Modify

- `EDIT: .agents/scripts/pulse-todo-sync-workspace.sh:436-457` — in `_ptsw_effective_recovery_cap`, return the configured cap when `candidate_count <= cap`, return `candidate_count` when it also reaches the count threshold, and only otherwise measure temp-root usage. Results are identical for every input.
- `NEW: _dlw_timed_log_and_prebootstrap` in `.agents/scripts/pulse-dispatch-worker-gates.sh` (after `_dlw_prebootstrap_gates`) — wraps `_dlw_setup_worker_log` and `_dlw_prebootstrap_gates` with `_ds_stage_start`/`_ds_record` (stages `setup_worker_log`, `prebootstrap_gates`), sets `_DLW_WORKER_LOG`, and keeps the existing `prebootstrap_gate` pre-runtime failure path.
- `EDIT: .agents/scripts/pulse-dispatch-worker-launch.sh:1865-1870` — the orchestrator calls the wrapper (100 → 96 lines, under the function-complexity gate).
- `EDIT: .agents/scripts/tests/test-precreation-failure-skip.sh:253` — stub `_ds_stage_start` beside the existing `_ds_record` stub, as other dispatch suites do.
- `EDIT: .agents/scripts/tests/test-pulse-worker-temp-dir.sh:18` — unset `AIDEVOPS_TEMP_DIR` in setup. The suite inherited the caller's value, failed its sweep case, and ran delete-mode sweeps plus three full `du` scans (103.8s) against the caller's real temp root.

### Complete Write Surface

- **Callers/readers:** `_ptsw_effective_recovery_cap` has one caller, `_ptsw_sweep_stale_workspaces`, reached from `aidevops_pulse_tmp_cleanup` (worker launch) and `pulse-temp-worktree-cleanup.sh:510` (cycle cleanup). `_dlw_setup_worker_log` and `_dlw_prebootstrap_gates` have one production caller each, the orchestrator.
- **Writers/mutation paths:** no change to which workspaces the sweep removes; `dispatch-stages.tsv` gains `dedup.setup_worker_log` and `dedup.prebootstrap_gates` records in the existing format.
- **Existing verification/tests:** listed below.
- **Schemas/config:** none; `PULSE_TODO_SYNC_PRESSURE_*` keep their meaning.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/`.
- **Migrations/backfills:** none.
- **Cleanup/rollback paths:** revert the commit.

### Implementation Steps

1. Short-circuit `_ptsw_effective_recovery_cap`.
2. Add the timed wrapper and call it from the orchestrator.
3. Stub `_ds_stage_start` in the precreation suite; make the temp-dir suite hermetic.
4. Run ShellCheck and the suites below on Bash 5 and `/bin/bash` 3.2.

### Hazards and Compatibility

- **Equivalence:** both pressure rules require `candidate_count > cap`, and the count rule wins before size is consulted. An old-versus-new comparison with a fake `du` matched on 11 cases (under/at/over cap, count and size pressure, size threshold ±1 KiB, zero candidates, invalid cap) on Bash 5 and 3.2; `du` ran only in the 4 size-pressure cases.
- **Instrumentation:** stage writes are fail-open; `_ds_stage_start` is defined wherever `pulse-dispatch-core.sh` is loaded.
- **Bash 3.2:** no new constructs.

### Complexity Impact

- **Target function:** `_dispatch_launch_worker` in `.agents/scripts/pulse-dispatch-worker-launch.sh`
- **Current line count:** 100 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** −4 lines
- **Projected post-change:** 96 lines
- **Action required:** None — the timing lives in the new 23-line wrapper.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/pulse-todo-sync-workspace.sh .agents/scripts/pulse-dispatch-worker-gates.sh .agents/scripts/pulse-dispatch-worker-launch.sh .agents/scripts/tests/test-precreation-failure-skip.sh .agents/scripts/tests/test-pulse-worker-temp-dir.sh
bash .agents/scripts/tests/test-pulse-todo-sync-stale-cleanup.sh
bash .agents/scripts/tests/test-pulse-worker-temp-dir.sh
bash .agents/scripts/tests/test-precreation-failure-skip.sh
bash .agents/scripts/tests/test-dispatch-min-concurrency.sh
```

- **Surface mapping:** the stale-cleanup suite drives the real cap under count pressure; the temp-dir suite drives the real `aidevops_pulse_tmp_cleanup` and `_dlw_setup_worker_log`; the precreation suite drives the real orchestrator.
- **Live check after release and update:** `dispatch-stages.tsv` shows `dedup.setup_worker_log` completions in seconds, and the gap between `eligibility_gate` and `resolve_tier_model` start falls well below the p50 of 64.9s.
- **Broad verification trigger:** Not required — no shared contract, root tooling or release infrastructure change.

### Recoverability Checkpoint

- [x] Focused functional verification passes
- [x] WIP commit created before broad gates
- [x] Evidence-triggered broad verification then run: not required — scoped modules

### Scope Boundaries

**Hard boundaries:** do not change which workspaces the sweep removes, the cap defaults, the gate order, or the per-candidate timeout.

**Not in scope (follow-up):** leaked GitHub transport temp files in the same root (12,171 `gh-request-attempts.*`, 7,484 `gh-transport-error.*`, 7,274 `gh-transport-meta.*`; 762 entries older than 7 days). They are removed on normal exit, but nothing traps a kill and nothing reaps them later.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/pulse-todo-sync-workspace.sh`
- `.agents/scripts/pulse-dispatch-worker-gates.sh`
- `.agents/scripts/pulse-dispatch-worker-launch.sh`
- `.agents/scripts/tests/test-precreation-failure-skip.sh`
- `.agents/scripts/tests/test-pulse-worker-temp-dir.sh`
- `TODO.md`
- `todo/tasks/t18674-brief.md`

## Acceptance Criteria

- [ ] The recovery cap measures temp-root usage only when candidates exceed the cap and stay below the count threshold.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-todo-sync-stale-cleanup.sh"
  ```

- [ ] The pre-model launch window writes `setup_worker_log` and `prebootstrap_gates` stage records.

  ```yaml
  verify:
    method: codebase
    pattern: "_ds_stage_start \"\\$issue_number\" \"\\$repo_slug\" \"setup_worker_log\""
    path: ".agents/scripts/pulse-dispatch-worker-gates.sh"
  ```

- [ ] Launch orchestration keeps its gate order and return codes.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-precreation-failure-skip.sh"
  ```

- [ ] After release and update, the untimed launch gap shrinks on this runner.

  ```yaml
  verify:
    method: manual
    prompt: "dedup.setup_worker_log completions in ~/.aidevops/logs/dispatch-stages.tsv take seconds, not tens of seconds"
  ```

## Context & Decisions

- **Short-circuit, not a new cache or schedule:** the size signal stays available for the one configuration where it matters.
- **Wrapper, not inline timing:** `_dispatch_launch_worker` sat at the 100-line gate.
- **Entry records:** `_ds_stage_start` keeps a killed stage attributable, which completion-only records cannot.

## Relevant Files

- `.agents/scripts/pulse-todo-sync-workspace.sh:436` — `_ptsw_effective_recovery_cap`
- `.agents/scripts/pulse-temp-helper.sh:57` — `aidevops_pulse_tmp_cleanup`
- `.agents/scripts/pulse-dispatch-worker-launch.sh:237` — `_dlw_setup_worker_log`
- `.agents/scripts/pulse-dispatch-worker-gates.sh:488` — `_dlw_prebootstrap_gates`
- `.agents/scripts/dispatch-stage-instrument.sh:101` — `_ds_stage_start`

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing directly; shortens every worker launch on runners with a large temp root
- **External:** none

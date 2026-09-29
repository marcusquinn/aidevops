<!-- aidevops:brief-schema=v2 -->

# t18560: Label-maintenance substage starvation leaves stale needs-simplification labels

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** While verifying post-merge state for #32638 (dispatch-ceremony performance), the session found that `needs-simplification` was still held although #33072 (GH#28839) had reduced the cited file below threshold. Pulse logs showed that the simplification re-evaluation substage had not completed for four days. Filed under ambient-capture policy for auto-dispatch.

## What

Every `_preflight_label_maintenance` substage completes regularly, even when an earlier substage is slow or times out. Specifically, `_reevaluate_simplification_labels` must run at least once per day on a normal install, so resolved `needs-simplification` holds clear without human action.

## Why

- `_preflight_label_maintenance` (`.agents/scripts/pulse-dispatch-preflight-lib.sh:326-355`) runs three substages in fixed order:
  1. `_reevaluate_consolidation_labels`
  2. `_backfill_stale_consolidation_labels`
  3. `_reevaluate_simplification_labels`
- The whole stage is bounded by `_pulse_run_budget_priority_stage_with_timeout "preflight_label_maintenance"` and is deferred when post-label refill budget is short (`.agents/scripts/pulse-dispatch-engine.sh:1610`).
- Evidence from the maintainer install on 2026-09-29:
  - The last completed `substage:label_maintenance/reevaluate_simplification_labels` in `pulse-stage-timings.log` was 2026-09-25T22:55Z. Its prior runs took 104–219 s.
  - The same log shows `backfill_consolidation_labels` taking 223–258 s and `reevaluate_consolidation_labels` taking 24–52 s.
  - `pulse.log` holds 16 lines of `preflight_label_maintenance deferred: insufficient wall-clock budget for post-label refill` and 8 lines of `Stage timeout: preflight_label_maintenance exceeded 217s`.
- **Impact:** #32638 is still held by `needs-simplification`. The gate flagged `.agents/scripts/pulse-dispatch-worker-launch.sh` at 2,020 lines, but #33072 reduced it to 1,811 lines and closed #28839. The only code path that clears the stale label is the re-evaluation substage, and it never runs.
- `_reevaluate_simplification_labels` (`.agents/scripts/pulse-triage-evaluation.sh:592-670`) also makes one `gh issue view --json body` call per labelled issue, after a `gh_issue_list` that could return the body directly.

## Tier

**Selected tier:** `tier:standard`

This is a scheduling change inside one stage function plus a REST-call reduction in one loop. The files and reference patterns are known, and the existing wiring test defines the contract. It is not `tier:simple`, because fair ordering needs small persisted state and the per-substage REST gates must be preserved exactly.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-preflight-lib.sh:326-355`:
  - Replace the fixed substage order with stalest-first ordering. Persist a last-completed epoch per substage in a small state file under the pulse state directory, using the same directory the stage-timing helpers already use.
  - Sort the three substages by last-completed epoch, oldest first; a missing epoch counts as oldest. Tie order is the current order.
  - Record the epoch only after the substage returns.
  - Keep the per-substage `_preflight_rest_core_allows_next "<context>" || return 0` gate immediately before each substage, with the existing context strings.
  - Keep the `_log_substage_timing` calls.
- `EDIT: .agents/scripts/pulse-triage-evaluation.sh:623-636`:
  - Request `--json number,body` in the existing `gh_issue_list` call.
  - Iterate the returned bodies instead of calling `gh issue view` once per issue.
  - Keep the `_pte_rest_core_deferrable_allows_next` gate per issue.
- `EDIT: .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh:270-321`:
  - Model new cases on `assert_label_maintenance_rest_block_contract`.
  - Assert that with a state file marking `simplification` as stalest, the event order starts with `gate:deferrable:label_maintenance_simplification_reevaluate;simplification;`.
  - Assert that a REST gate refusal still stops the stage at that substage.
  - Point the state file at a temporary directory in the test.

### Complete Write Surface

- **Callers/readers:**
  - `.agents/scripts/pulse-dispatch-engine.sh` runs `_preflight_label_maintenance` through the budget-priority stage wrapper.
  - `pulse-stage-timings.log` readers see the same substage names.
- **Writers/mutation paths:** `.agents/scripts/pulse-dispatch-preflight-lib.sh` writes a new per-substage epoch state file, the only new persisted state. Label edits remain inside the existing substage functions in `.agents/scripts/pulse-triage-evaluation.sh`.
- **Schemas/config:**
  - The new state file is plain `name epoch` lines.
  - There are no new environment variables unless one is needed for test isolation. If so, use `AIDEVOPS_LABEL_MAINTENANCE_STATE_FILE`.
- **Generated/deployed mirrors:** `setup.sh` deploys the changed scripts to `~/.aidevops/agents/scripts/`.
- **Migrations/backfills:** N/A because no existing state is converted. A missing state file means every substage is equally stale, which gives the current order.
- **Cleanup/rollback paths:** N/A because rollback is a plain revert of `.agents/scripts/pulse-dispatch-preflight-lib.sh`, and the old code ignores a leftover state file.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh`.

### Implementation Steps

1. Add `_preflight_label_maintenance_order`, which prints the three substage keys stalest-first from the state file. Validate that each epoch matches `^[0-9]+$`; treat invalid lines as missing.
2. Rewrite `_preflight_label_maintenance` to loop over that order. Dispatch each key to its existing REST context, function and timing name through a `case` statement, and write the epoch after each substage completes. Use an atomic temp-file-then-`mv` write.
3. In `_reevaluate_simplification_labels`, fetch the bodies with the issue list and remove the per-issue `gh issue view`.
4. Update the wiring test's expected strings, add the stalest-first and gate-refusal cases, and run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** only one pulse cycle runs label maintenance at a time, under the pulse lock, and the atomic `mv` avoids torn state.
- **Migration/rollback:** there is no migration. Rollback is a revert, and the orphaned state file is harmless.
- **Stage timeout:** the stage can still be killed mid-substage. The epoch is written only after completion, so a killed substage stays stalest and runs first next time. A substage that always exceeds the stage timeout would starve the others, so log a warning when the same substage is first three cycles in a row without completing.
- **Mixed-version/backward compatibility:**
  - Substage names in the timing logs are unchanged.
  - Consolidation behaviour is unchanged apart from ordering.
- **Idempotency/retry:** every substage is already idempotent.
- **Partial failure/recovery:** an unreadable state file falls back to the current fixed order.

### Complexity Impact

- **Target function:** `_preflight_label_maintenance` in `.agents/scripts/pulse-dispatch-preflight-lib.sh`
- **Current line count:** 30 lines (L326-355; the function-complexity threshold is 100 lines)
- **Estimated growth:** about +15 lines in the function, plus a new helper of about 25 lines
- **Projected post-change:** about 45 lines
- **Action required:** none

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-dispatch-preflight-lib.sh .agents/scripts/pulse-triage-evaluation.sh .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
```

- **Surface mapping:**
  - `shellcheck` covers all changed scripts.
  - The wiring test proves stalest-first ordering, preserved REST gating and the timeout fallback order.
- **Broad verification trigger:** not required, because there are no shared config, root tooling or workflow YAML changes.

### Scope Boundaries

**Hard boundaries:**

- Do not change the stage timeout, the budget-priority classification or the refill-reserve logic in `pulse-dispatch-engine.sh`.
- Do not change what any substage decides. Only ordering and the body fetch change.
- Do not change the large-file gate's thresholds or path extraction.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-dispatch-preflight-lib.sh`
- `.agents/scripts/pulse-triage-evaluation.sh`
- `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] Label-maintenance substages run stalest-first, and a substage that did not complete runs first on the next eligible cycle.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh"
  ```

- [ ] `_reevaluate_simplification_labels` makes no per-issue `gh issue view` call.

  ```yaml
  verify:
    method: codebase
    pattern: "--json number,body"
    path: ".agents/scripts/pulse-triage-evaluation.sh"
  ```

- [ ] Negative/regression: a REST gate refusal still stops label maintenance at that substage, and a missing or corrupt state file gives the current fixed order.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh"
  ```

- [ ] Changed-file lint is clean: `shellcheck .agents/scripts/pulse-dispatch-preflight-lib.sh .agents/scripts/pulse-triage-evaluation.sh .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh`
- [ ] Post-deploy check (maintainer): within 24 h, `pulse-stage-timings.log` records a `reevaluate_simplification_labels` completion. #32638 then loses `needs-simplification` if every cited file is under threshold. #32638 also cites `.agents/scripts/tests/test-dispatch-claim-helper.sh` (2,095 lines); if the gate flags that file, the hold is new and correct, not a regression.

## Context & Decisions

- This brief chooses stalest-first ordering over splitting the stage. Separate stages would each need their own budget-priority and refill-reserve wiring in `pulse-dispatch-engine.sh`. Ordering fixes starvation with one local change.
- Making `backfill_consolidation_labels` faster is a separate optimisation. Fair ordering is needed anyway, so that any future slow substage cannot starve the others.
- Related: #28880 moved label maintenance after the first dispatch, which is the reason the stage now competes with the refill budget. #32259 bounded the backfill substage's `gh` calls.

## Relevant Files

- `.agents/scripts/pulse-dispatch-preflight-lib.sh:306-355`: REST gate helper and the label-maintenance stage
- `.agents/scripts/pulse-triage-evaluation.sh:592-670`: simplification re-evaluation
- `.agents/scripts/pulse-dispatch-engine.sh:1605-1620`: stage deferral on insufficient budget
- `.agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh:270-360`: label-maintenance contract tests

<!-- aidevops:brief-schema=v2 -->

## Pre-flight

- [x] Memory recall: `pulse-check budget timed_out history queue coverage routine` → 0 relevant hits.
- [x] Discovery pass: no open issue or PR changes `pulse-check-helper.sh` budgets or the `r-pulse-check` routine (searched 2026-11-19).
- [x] File refs verified: paths below exist at `main`.
- [x] Tier: `tier:standard`. Mode-dependent defaults in one helper, plus removal of a duplicate routine entry.

## Origin

- **Created:** 2026-11-19
- **Created by:** AI DevOps interactive session (worker throughput investigation)
- **Conversation context:** r915 (`pulse-check-helper.sh apply`, daily 06:20) is the routine that should turn recurring worker failure families into self-improvement issues without a human. Across the last 13 runs in `~/.aidevops/logs/pulse-routines-tick.log`, the 24 h worker-history collector timed out at its 10 s component budget 6 times, including both runs on 2026-11-18 and 2026-11-19 (`"history":{"state":"timed_out","exit_code":124,"elapsed_seconds":10}`). The queue scan covered all 70 repos in only 2 runs; the latest covered 3/70 with `queue_budget_exhausted`. Every run ended `pulse-check: no autofile findings above thresholds`. The same 24 h summary completes in 3 s on an idle host but exceeds 10 s at 06:20 with 17/20 workers running. The routine is documented as `~5m` (`routines/core-routines.sh:936`), yet it runs with the interactive `report` budget (45 s total, 10 s per component, 20 s queue). Separately, the `marcusquinn/aidevops` `TODO.md` still holds a repo-local `r-pulse-check` entry (added with r915 in #26100) that runs the same `pulse-check-helper.sh apply` at the same slot, so pulse-check runs twice a day on this repo's host.

## What

1. Give `apply` (the scheduled routine) budgets sized for the routine: 300 s total, 60 s per component, 210 s queue scan (a full 70-repo scan measured 136 s on a loaded host on 2026-11-19; 210 s leaves ~50% headroom inside the `~5m` routine estimate). Keep `report`/`json` at 45 s / 10 s / 20 s. Explicit `--budget`, `PULSE_CHECK_REPORT_BUDGET_SECONDS`, `PULSE_CHECK_COMPONENT_BUDGET_SECONDS` and `PULSE_CHECK_QUEUE_BUDGET_SECONDS` still win.
2. Remove the duplicate `r-pulse-check` routine from `TODO.md`; r915 is the framework-managed entry that reaches every install.

## Why

When history times out, failure-family evidence is empty and nothing is ever autofiled. Recurring worker regressions then wait for a human to notice them in an interactive session, the dependency this routine exists to remove. Running the helper twice per slot doubles its API and CPU cost and lets two writers race on the same dedupe marker.

## Tier

`tier:standard`.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/pulse-check-helper.sh:34`, `:105-128`, `:151-153`. Leave `REPORT_BUDGET_SECONDS` empty unless set by env or `--budget`. After argument parsing, resolve it and new `COMPONENT_BUDGET_SECONDS` / `QUEUE_BUDGET_SECONDS` defaults from `APPLY_MODE`. `_run_json_helper` uses `${_PULSE_CHECK_COMPONENT_BUDGET:-$COMPONENT_BUDGET_SECONDS}`; `_scan_auto_dispatch_queue` uses `QUEUE_BUDGET_SECONDS`. Update `--budget` help text.
- EDIT: `TODO.md:98`. Delete the `r-pulse-check` line.
- EDIT: `.agents/scripts/tests/test-pulse-routines-selector.sh:331-333`. Case 7b asserts `r-pulse-check` is a live descriptive ID; drop that assertion and keep the `r-gh-audit-scan` (descriptive ID) and fenced-`r004` assertions. `_collect_routine_ids` returns only enabled `[x]` routines, so a disabled entry such as `r-runtime-audit` cannot substitute.
- EDIT: `.agents/scripts/routines/core-routines.sh:953-958`. One safety-rail line documenting the routine budget.

### Files Scope

- `.agents/scripts/pulse-check-helper.sh`
- `.agents/scripts/tests/test-pulse-routines-selector.sh`
- `.agents/scripts/routines/core-routines.sh`
- `TODO.md`

### Reference pattern

- `--verify-delivery` already raises one component's budget explicitly (`pulse-check-helper.sh:213-215`).

## Acceptance Criteria

- [ ] `bash .agents/scripts/tests/test-pulse-check-helper.sh` and `bash .agents/scripts/tests/test-pulse-routines-selector.sh` pass.
- [ ] `pulse-check-helper.sh json` still reports a 45 s collection budget; `pulse-check-helper.sh apply` resolves 300/60/210 unless overridden.
- [ ] ShellCheck reports no warnings for the changed shell files.
- [ ] After deploy, the next r915 run in `pulse-routines-tick.log` shows `"history":{"state":"ok"` and queue coverage `70/70`, and r915 is the only routine dispatching `pulse-check-helper.sh apply` at 06:20.

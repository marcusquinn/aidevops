---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2013: refactor: split headless-runtime-helper.sh below 2000 LOC simplification gate

## Origin

- **Created:** 2026-04-12
- **Session:** claude:refactor/headless-runtime-simplify
- **Created by:** Marcus Quinn (ai-interactive)
- **Conversation context:** User requested an interactive simplification of `headless-runtime-helper.sh` (3123 LOC) so any issue that targets it stops triggering the `LARGE_FILE_LINE_THRESHOLD` (2000) gate in `pulse-dispatch-core.sh _issue_targets_large_files()`. Without this, every dispatched task touching the helper gets the `needs-simplification` label and is held from worker dispatch.

## What

Split `headless-runtime-helper.sh` into a thin orchestrator (the helper) plus a stable utility library (`headless-runtime-lib.sh`), preserving all behavior. Both files must be under the 2000-line gate. The helper sources the lib once, near the top, after `shared-constants.sh` and `worker-lifecycle-common.sh`. No call sites or subprocess invocations change — `pulse-wrapper.sh`, `core-routines.sh`, and all CLI users continue to call `headless-runtime-helper.sh` as before.

## Why

- The 3123-line helper exceeds `LARGE_FILE_LINE_THRESHOLD=2000`, so `_issue_targets_large_files()` adds `needs-simplification` to every issue body that lists it under `EDIT:` / `NEW:` / `File:`. This blocks legitimate fixes from being dispatched.
- The simplification routine has filed and closed multiple complexity issues against this file historically (GH#15066, GH#14228, GH#6055, GH#5774). None addressed file size.
- The codebase already has the precedent: `issue-sync-helper.sh` (1569) + `issue-sync-lib.sh` (1376) demonstrates the same split.
- Net result: all fixes that touch headless dispatch can now be dispatched normally instead of being parked.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** No — 4 files (helper, new lib, 2 tests). `tier:standard`.
- [x] **Complete code blocks for every edit?** N/A — refactor is mechanical extraction.
- [x] **No judgment or design decisions?** Section boundaries needed judgment.
- [x] **No error handling or fallback logic to design?** Watchdog inline fallback retained.
- [x] **Estimate 1h or less?** ~2h with verification.
- [x] **4 or fewer acceptance criteria?** 6.

**Selected tier:** `tier:standard` (already implemented in this interactive session)

**Tier rationale:** Multi-file refactor with split-line judgment calls and test updates; not a single-file copy-paste. Implemented interactively to preserve all behavior and update guard tests in the same change.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/headless-runtime-helper.sh` — trim from 3123 to ~1198 lines; retain header constants, `cmd_select`, `cmd_backoff`, `cmd_session`, `cmd_metrics`, `_parse_run_args`, `_validate_run_args`, `_invoke_opencode`, `_invoke_claude`, `_handle_run_result`, `_execute_run_attempt`, `_cmd_run_finish`, `_cmd_run_prepare`, `_cmd_run_prepare_retry`, `_detach_worker`, `cmd_run`, `show_help`, `main`. Source the new lib after the existing `shared-constants.sh` / `worker-lifecycle-common.sh` sources.
- `NEW: .agents/scripts/headless-runtime-lib.sh` — ~1925 lines containing 14 numbered sections: state DB, provider auth, backoff parsing/recording, output parsing, metrics, sandbox passthrough, worker contract, activity watchdog (inline fallback), DB merge, dispatch ledger / session locks, failure reporting, canary + version pin, model choice, OpenCode server detection + cmd builders. Idempotent guard via `_HEADLESS_RUNTIME_LIB_LOADED`.
- `EDIT: .agents/scripts/tests/test-headless-runtime-helper.sh` — update `HEADLESS_CONTINUATION_CONTRACT_V5` assertions to `V6` (pre-existing test/code drift surfaced as a guard for this refactor).
- `EDIT: .agents/scripts/tests/test-headless-contract-escalation.sh` — read contract heredoc and `append_worker_headless_contract` function from `headless-runtime-lib.sh` instead of `headless-runtime-helper.sh`; tighten the heredoc regex to anchor on `[HEADLESS_CONTINUATION_CONTRACT_V\d+]`; replace V1 markers with V6; rewrite the genuine-blockers assertion to match the actual V6 contract phrasing (`missing permission` + `explicit policy gate`) with legacy fallback.

### Implementation Steps

1. Create `headless-runtime-lib.sh` with all stable utility functions, preserving exact code, comments, and behavior. Use single-line section banners (`# --- N. Title ---`) to keep the lib comfortably under 2000.
2. Rewrite `headless-runtime-helper.sh` from scratch (cleaner than surgical deletion): header, constants, source the lib, then orchestration functions, then `show_help` and `main`. Keep `HEADLESS_ACTIVITY_TIMEOUT_SECONDS` at the top of the helper since the helper is the only consumer.
3. Update both test files. Re-run them to confirm 4/4 + 8/8 passing.
4. Run `shellcheck --severity=warning` on helper, lib, and both tests. Confirm exit 0.
5. Run `wc -l` on both files. Confirm both are under 2000.

### Verification

```bash
wc -l .agents/scripts/headless-runtime-helper.sh .agents/scripts/headless-runtime-lib.sh
# helper:  1198 lines  (was 3123)
# lib:     1925 lines  (new file)
bash -n .agents/scripts/headless-runtime-helper.sh
bash -n .agents/scripts/headless-runtime-lib.sh
shellcheck --severity=warning \
  .agents/scripts/headless-runtime-helper.sh \
  .agents/scripts/headless-runtime-lib.sh \
  .agents/scripts/tests/test-headless-runtime-helper.sh \
  .agents/scripts/tests/test-headless-contract-escalation.sh
bash .agents/scripts/tests/test-headless-runtime-helper.sh        # 4/4 PASS
bash .agents/scripts/tests/test-headless-contract-escalation.sh   # 8/8 PASS
.agents/scripts/headless-runtime-helper.sh --help                  # smoke test
.agents/scripts/headless-runtime-helper.sh select --role worker    # returns selected model
.agents/scripts/headless-runtime-helper.sh passthrough-csv         # returns env CSV
.agents/scripts/headless-runtime-helper.sh metrics                 # analyses metrics file
.agents/scripts/headless-runtime-helper.sh backoff status          # queries DB
```

## Acceptance Criteria

- [x] `headless-runtime-helper.sh` is below 2000 lines (target ~1100-1300; achieved 1198).
- [x] `headless-runtime-lib.sh` exists, is below 2000 lines, and is sourced exactly once by the helper.
- [x] Behavior is preserved: every public/private function name is unchanged, every CLI subcommand still works (`select`, `run`, `backoff`, `session`, `metrics`, `passthrough-csv`, `help`).
- [x] `shellcheck --severity=warning` exits 0 for the helper, the lib, and both updated tests.
- [x] `test-headless-runtime-helper.sh` is 4/4 PASS (was 3/4 — fixed pre-existing V5/V6 drift in the same change).
- [x] `test-headless-contract-escalation.sh` is 8/8 PASS (was 6/8 — updated to read from the lib and corrected V1→V6 + genuine-blockers wording).

## Context

- Helper precedent: `.agents/scripts/issue-sync-helper.sh` + `.agents/scripts/issue-sync-lib.sh`.
- Gate logic: `.agents/scripts/pulse-dispatch-core.sh:_issue_targets_large_files()` and `LARGE_FILE_LINE_THRESHOLD` (default 2000) at `.agents/scripts/pulse-wrapper.sh:777`.
- The helper is invoked as a subprocess by `pulse-wrapper.sh` and `routines/core-routines.sh` — no callers source it for function-level access. Only the two test files extract internal heredoc/function bodies via regex; both are updated in this PR.
- The pre-existing V5/V6 drift in `test-headless-runtime-helper.sh` was a latent broken test, not caused by this refactor. It was fixed in scope because the test is the guard for the split.

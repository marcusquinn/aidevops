<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1431: Refactor — extract stats functions from pulse-wrapper into stats-wrapper

## Origin

- **Created:** 2026-03-10
- **Session:** opencode (interactive, t1429 follow-up)
- **Created by:** alex-solovyev (human + ai-interactive)
- **Parent task:** t1429
- **Conversation context:** After t1429 separated stats into a separate cron process, analysis showed 41% of pulse-wrapper.sh (13 functions, ~1473 lines) is stats-only code that pulse no longer calls. stats-wrapper.sh currently sources the entire 3536-line pulse-wrapper just to access these functions.

## What

Extract 12 stats-only functions from `pulse-wrapper.sh` into `stats-wrapper.sh` (or a dedicated `stats-functions.sh` sourced by stats-wrapper). Keep `check_session_count` in pulse-wrapper (shared — used by both `main()` and `_update_health_issue_for_repo`). pulse-wrapper shrinks by ~1400 lines; stats-wrapper stops sourcing the entire pulse-wrapper.

## Why

- **Separation of concerns:** 41% of pulse-wrapper is dead code from pulse's perspective — it only exists as a library for stats-wrapper
- **Reduced blast radius:** sourcing 3536-line pulse-wrapper into stats-wrapper imports all pulse functions, config, and side effects unnecessarily
- **Maintainability:** easier to reason about each script when it only contains its own logic
- **Startup cost:** stats-wrapper loads and parses 3536 lines to use 1473 — wasted I/O

## How (Approach)

1. Create `.agents/scripts/stats-functions.sh` containing the 12 extracted functions
2. `stats-wrapper.sh` sources `shared-constants.sh` + `worker-lifecycle-common.sh` + `stats-functions.sh` (no longer sources pulse-wrapper)
3. `pulse-wrapper.sh` loses 12 function definitions (~1400 lines removed)
4. `check_session_count` stays in pulse-wrapper; `stats-functions.sh` sources pulse-wrapper only for that one function OR duplicates it (17 lines — acceptable)
5. Verify config variables (`REPOS_JSON`, `LOGFILE`, `QUALITY_SWEEP_*`, `PERSON_STATS_*`) are defined in the right place

### Functions to extract (12):

| Function | Lines | Notes |
|----------|-------|-------|
| `update_health_issues` | 58 | entry point |
| `run_daily_quality_sweep` | 47 | entry point |
| `_refresh_person_stats_cache` | 89 | called by update_health_issues |
| `_update_health_issue_for_repo` | 433 | largest, generates health dashboard |
| `_quality_sweep_for_repo` | 422 | per-repo quality scan |
| `_update_quality_issue_body` | 207 | formats quality issue |
| `_ensure_quality_issue` | 69 | creates/finds quality GitHub issue |
| `_cleanup_stale_pinned_issues` | 45 | |
| `_unpin_health_issue` | 19 | |
| `_get_runner_role` | 36 | only used by _update_health_issue_for_repo |
| `_load_sweep_state` | 16 | |
| `_save_sweep_state` | 15 | |

### Shared (stays in pulse-wrapper):

| Function | Lines | Used by |
|----------|-------|---------|
| `check_session_count` | 17 | `main()` + `_update_health_issue_for_repo` |

## Acceptance Criteria

- [ ] `pulse-wrapper.sh` does not define any of the 12 extracted functions
  ```yaml
  verify:
    method: codebase
    pattern: "^(_update_health_issue_for_repo|_quality_sweep_for_repo|_update_quality_issue_body|_ensure_quality_issue|_refresh_person_stats_cache|_cleanup_stale_pinned_issues|_unpin_health_issue|_get_runner_role|_load_sweep_state|_save_sweep_state|run_daily_quality_sweep|update_health_issues)\\(\\)"
    path: ".agents/scripts/pulse-wrapper.sh"
    expect: absent
  ```
- [ ] `stats-functions.sh` or `stats-wrapper.sh` defines all 12 functions
  ```yaml
  verify:
    method: bash
    run: "grep -c '() {' .agents/scripts/stats-functions.sh | test $(cat) -ge 12"
  ```
- [ ] `stats-wrapper.sh` does NOT source `pulse-wrapper.sh`
  ```yaml
  verify:
    method: codebase
    pattern: "source.*pulse-wrapper"
    path: ".agents/scripts/stats-wrapper.sh"
    expect: absent
  ```
- [ ] `check_session_count` remains in `pulse-wrapper.sh`
  ```yaml
  verify:
    method: codebase
    pattern: "^check_session_count\\(\\)"
    path: ".agents/scripts/pulse-wrapper.sh"
  ```
- [ ] ShellCheck clean on all modified scripts
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-wrapper.sh .agents/scripts/stats-wrapper.sh .agents/scripts/stats-functions.sh 2>&1 | grep -v SC1091 | grep -c 'error\\|warning' | test $(cat) -eq 0"
  ```
- [ ] stats-wrapper.sh runs successfully (dry run or with timeout)

## Context & Decisions

- `check_session_count` is shared — duplicating 17 lines is acceptable vs introducing a cross-source dependency
- stats-functions.sh as a separate file (not inline in stats-wrapper) keeps stats-wrapper thin and testable
- Config variables (`REPOS_JSON`, `QUALITY_SWEEP_*`, `PERSON_STATS_*`) need to move with the functions or be sourced from shared-constants.sh

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:1569-3167` — functions to extract
- `.agents/scripts/stats-wrapper.sh` — needs to stop sourcing pulse-wrapper
- `.agents/scripts/shared-constants.sh` — may need new config constants

## Dependencies

- **Blocked by:** none (t1429 merged)
- **Blocks:** nothing critical (cosmetic/maintenance)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | function boundaries already mapped |
| Implementation | 1.5h | extract, rewire, test |
| Testing | 30m | shellcheck, dry run, cron verify |
| **Total** | **~2h** | |

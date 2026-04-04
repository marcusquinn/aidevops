<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1429: Separate stats from pulse — prevent rate-limit blocking

## Origin

- **Created:** 2026-03-10
- **Session:** opencode:ses_3271deae6ffeB626iF1sxHYePP
- **Created by:** alex-solovyev (human + ai-interactive)
- **Conversation context:** User observed pulse processes stuck in infinite rate-limit wait loops. Root cause analysis revealed `contributor-activity-helper.sh` blocks on GitHub Search API rate limits (30 req/min), and this runs inside `pulse-wrapper.sh main()` BEFORE `run_pulse()`, preventing any useful work (dispatch, merge) from ever executing.

## What

1. **Remove stats from pulse-wrapper.sh** — `run_daily_quality_sweep` and `update_health_issues` (which calls `_refresh_person_stats_cache` -> `contributor-activity-helper.sh`) must not run in the pulse process at all.
2. **Create `stats-wrapper.sh`** — a separate cron-schedulable script that runs quality sweep, health issues, and person-stats on its own schedule (e.g., every 15-30 min) with its own PID dedup and a hard timeout.
3. **Fix `contributor-activity-helper.sh`** — the rate-limit wait loop (line ~1035) must bail out instead of sleeping indefinitely. Return partial results when budget is exhausted.
4. **Wire cron** — `setup.sh` installs the stats cron entry alongside the pulse entry.

## Why

The pulse is the only mechanism for dispatching workers and merging PRs. When stats block it, zero useful work gets done. The pulse log showed hours of `Rate limit low (0 remaining), waiting 56s...` with the pulse never reaching `run_pulse()`. This is a production blocker — the entire autonomous orchestration system is dead when stats consume the Search API budget.

## How (Approach)

- `pulse-wrapper.sh:main()` — remove `run_daily_quality_sweep` and `update_health_issues` calls, update the execution order comment
- New `.agents/scripts/stats-wrapper.sh` — extract stats logic into standalone script with PID dedup, hard timeout (10 min), and its own log file (`~/.aidevops/logs/stats.log`)
- `contributor-activity-helper.sh:person_stats()` — replace infinite sleep loop with a max-retries (1) approach: if budget < 5, skip remaining users and return partial results
- `setup.sh` — add `stats-wrapper` cron entry (every 15 min)

Key files:
- `.agents/scripts/pulse-wrapper.sh:3276` — main() function
- `.agents/scripts/contributor-activity-helper.sh:1031` — blocking for loop
- `setup.sh` — cron installation

## Acceptance Criteria

- [ ] `pulse-wrapper.sh main()` does not call `run_daily_quality_sweep` or `update_health_issues`
  ```yaml
  verify:
    method: codebase
    pattern: "run_daily_quality_sweep|update_health_issues"
    path: ".agents/scripts/pulse-wrapper.sh"
    expect: absent
  ```
- [ ] `stats-wrapper.sh` exists and is executable
  ```yaml
  verify:
    method: bash
    run: "test -x .agents/scripts/stats-wrapper.sh"
  ```
- [ ] `contributor-activity-helper.sh` does not sleep indefinitely on rate limit — bails out with partial results
  ```yaml
  verify:
    method: codebase
    pattern: "sleep.*wait_secs"
    path: ".agents/scripts/contributor-activity-helper.sh"
    expect: absent
  ```
- [ ] ShellCheck clean on modified scripts
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/pulse-wrapper.sh .agents/scripts/stats-wrapper.sh .agents/scripts/contributor-activity-helper.sh"
  ```

## Context & Decisions

- Stats were originally placed before pulse (GH#2958) to "not eat into pulse time" — but the blocking rate-limit loop made this worse than the original problem
- Person-stats cache (t1426) tried to fix this by gating on Search API budget, but the blocking loop inside `contributor-activity-helper.sh` itself was never fixed
- The pulse progress watchdog doesn't catch this because the rate-limit loop writes to stderr -> log grows -> progress detection sees "activity"

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:3276` — main() to modify
- `.agents/scripts/pulse-wrapper.sh:2149` — `_refresh_person_stats_cache()` to extract
- `.agents/scripts/pulse-wrapper.sh:2245` — `update_health_issues()` to extract
- `.agents/scripts/contributor-activity-helper.sh:1031` — blocking for loop to fix
- `setup.sh` — cron installation

## Dependencies

- **Blocked by:** none
- **Blocks:** pulse functionality (currently dead)
- **External:** none

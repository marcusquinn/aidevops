<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1423: Priority-class worker reservations for per-repo concurrency fairness

## Session Origin

Interactive session, 2026-03-09. User asked whether workers still share concurrency across all repos.json. Confirmed yes — global pool with no per-class partitioning. User chose option 2 (priority-class reservations) over per-repo min/max or status quo.

## What

Add priority-class worker slot reservations to the pulse supervisor. Product repos (`"priority": "product"` in repos.json) get a guaranteed minimum share of worker slots (default 60%). Tooling repos get the remainder. Soft reservation — when one class has no pending work, the other can use freed slots.

## Why

Without reservations, tooling hygiene work (quality-debt, simplification-debt, CI fixes) can consume all worker slots before product repos' new features get dispatched. The existing priority order in pulse.md (item 5: "product over tooling") is LLM guidance, not enforcement — a busy tooling repo with many failing-CI PRs (priority 1-2) consumes all slots before product repos' lower-priority issues get a chance.

## How

1. **pulse-wrapper.sh**: Add `PRODUCT_RESERVATION_PCT` config (default 60%), `calculate_priority_allocations()` function that reads repos.json, counts product vs tooling repos, computes `PRODUCT_MIN` and `TOOLING_MAX`, writes to `~/.aidevops/logs/pulse-priority-allocations`.
2. **pulse-wrapper.sh**: Add `_append_priority_allocations()` to format allocation data for the STATE_FILE.
3. **pulse.md**: Update Step 1 to read allocation file and enforce class reservations before dispatch. Update priority order item 5 to reference enforcement. Update Hard Rule 6.

## Acceptance Criteria

- [ ] `calculate_priority_allocations()` correctly computes allocations for: normal case, small pool, 1 worker, no tooling, no product repos
- [ ] Allocation data appears in pulse state file
- [ ] pulse.md Step 1 includes class enforcement guidance
- [ ] ShellCheck clean (SC1091 only)
- [ ] All existing pulse-wrapper tests still pass

## Context

- 8 pulse-enabled repos: 4 product (cloudron-netbird-app, turbostarter-plus, webapp, essentials.com), 4 tooling (aidevops, aidevops.sh, quickfile-mcp, aidevops-cloudron-app)
- Current MAX_WORKERS is RAM-based: `(free_mb - 8GB) / 1GB`, capped at 8
- DAILY_PR_CAP=5 per repo already prevents PR flood, but doesn't prevent worker slot starvation
- Quality-debt cap (30%) and simplification-debt cap (10%) are global against MAX_WORKERS

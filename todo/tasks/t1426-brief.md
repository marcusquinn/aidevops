---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1426: Cache person_stats hourly to eliminate Search API rate limit exhaustion

## Origin

- **Created:** 2026-03-09
- **Session:** interactive (pulse-wrapper stability investigation)
- **Ref:** GH#4016

## What

Cache `person-stats` and `cross-repo-person-stats` results hourly instead of recomputing every pulse (every 2 min).

## Why

`person_stats()` makes 4 GitHub Search API calls per contributor (30 req/min limit). With 2 repos and ~5 contributors, each pulse burns 44 Search API calls — exceeding the 30/min limit. The function blocks for 56s waiting for rate limit reset, stalling the entire pulse cycle. The data (monthly contributor output) changes at most hourly.

## How

Add `_refresh_person_stats_cache()` to `pulse-wrapper.sh`:
- Timestamp guard: recompute only if last run > 1 hour ago
- Per-repo cache: `~/.aidevops/logs/person-stats-cache-{slug-safe}.md`
- Cross-repo cache: `~/.aidevops/logs/person-stats-cache-cross-repo.md`
- Timestamp file: `~/.aidevops/logs/person-stats-last-run`

Update `update_health_issues()` and `_update_health_issue_for_repo()` to read from cache files instead of calling `contributor-activity-helper.sh person-stats` directly. Remove the rate limit guards added as interim mitigation.

## Acceptance Criteria

- [ ] `_refresh_person_stats_cache()` exists with 1-hour timestamp guard
- [ ] Cache files written per-repo and cross-repo
- [ ] `_update_health_issue_for_repo()` reads person_stats from cache
- [ ] `update_health_issues()` reads cross-repo person_stats from cache
- [ ] Rate limit guards removed (no longer needed)
- [ ] ShellCheck clean
- [ ] Health issue still shows person stats table (from cache)

## Relevant Files

- `.agents/scripts/pulse-wrapper.sh:2154` — `update_health_issues()`
- `.agents/scripts/pulse-wrapper.sh:1626` — `_update_health_issue_for_repo()`
- `.agents/scripts/contributor-activity-helper.sh:922` — `person_stats()`

# t3591: Bound person-stats GitHub calls with portable timeouts

## Pre-flight

- [x] Memory recall: `close superseded PR create worker-ready issue auto-dispatch PR 23745 review issue brief` → 0 hits — no relevant lessons
- [x] Discovery pass: 11 recent commits / 0 recently merged related PRs / 1 open related PR touch or relate to target files in last 48h — only open duplicate is PR #23745
- [x] File refs verified: target script paths and `shared-constants.sh` timeout helper reference verified by review context; worker must re-check exact line numbers at implementation HEAD
- [x] Tier: `tier:standard` — multi-file shell change with timeout/fallback semantics and regression tests
- [x] Seeded draft PR decision recorded: skipped — existing PR #23745 is the seed/counterexample, and the replacement needs design correction before code reuse

## Origin

- **Created:** 2026-05-18
- **Session:** OpenCode interactive session
- **Created by:** ai-interactive
- **Task ref:** GH#23761
- **Source PR:** PR #23745
- **Conversation context:** Maintainer review confirmed PR #23745 identifies a real hang risk but uses a non-portable direct `timeout` wrapper and misses root GitHub API call handling. The user asked to file a new auto-dispatch brief and close the PR with a link.

## What

Implement a portable, root-cause fix so optional person-stats refreshes cannot hang the health dashboard indefinitely. The final behavior should bound slow/stuck GitHub API calls in the person-stats helper, work on bare macOS without GNU coreutils, and preserve useful partial/timeout information instead of silently replacing all failed stats with empty output.

## Why

`stats-health-dashboard-data.sh` calls `person-stats` and `cross-repo-person-stats` synchronously. Those paths can reach raw `gh api` calls in `contributor-activity-helper-person.sh` without a portable wall-clock deadline, so a slow or stuck GitHub call can block dashboard freshness. PR #23745 adds a caller-level `timeout 60`, but direct `timeout` is absent on bare macOS and one 60s aggregate budget may hide valid cross-repo partial results.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This spans multiple shell scripts and tests, requires fallback/error semantics, and asks the worker to choose safe timeout placement and budgets while following existing project patterns.

## PR Conventions

Leaf task: implementation PR should use a closing keyword for GH#23761.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** PR #23745 is useful evidence but not a safe seed because its direct `timeout` approach is the behavior to avoid. Issue-only dispatch gives the worker the corrected constraints without anchoring on the incomplete patch.
- **Status:** `not-created`
- **Freshness evidence:** PR #23745 review and prework discovery performed on 2026-05-18; only open related PR found was #23745.
- **Verification run:** UNVERIFIED — planning-only task filing; implementation worker must run tests.
- **Stale-assumption warning:** Re-check recent changes to the target scripts before editing, especially any new shared GitHub API wrapper or dashboard cache metadata changes.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/contributor-activity-helper-person.sh`
- EDIT: `.agents/scripts/stats-health-dashboard-data.sh`
- EDIT/NEW: focused shell test under `.agents/scripts/tests/` covering person-stats timeout behavior
- Reference pattern: use `.agents/scripts/shared-constants.sh` `timeout_sec` and existing shared GitHub cooldown/timeout wrappers; do not introduce direct GNU-only `timeout` usage.

### Implementation Steps

1. Inspect the raw `gh api` call sites in `.agents/scripts/contributor-activity-helper-person.sh` for `person-stats` and `cross-repo-person-stats`.
2. Centralize portable wall-clock protection near those GitHub API calls, using `timeout_sec` or an existing shared wrapper pattern rather than direct `timeout`.
3. Use separate or configurable budgets for single-person and cross-repo aggregate stats so cross-repo work does not lose useful partial output under a single hard-coded 60s budget.
4. Adjust `.agents/scripts/stats-health-dashboard-data.sh` so timeout/failure of optional person-stats does not mark a misleading successful refresh when both optional stats paths fail.
5. Preserve or surface partial-output/timeout markers in dashboard data where possible. Use jq fallback `//` and avoid redundant `"null"` string checks instead of silently converting failures to empty stats.
6. Add regression coverage for bare macOS/no-coreutils behavior by isolating `PATH` or faking command availability, plus slow/stuck helper behavior for both per-person and cross-repo paths.

### Verification

```bash
.agents/scripts/tests/test-stats-health-dashboard-data.sh
.agents/scripts/tests/test-contributor-activity-helper-person.sh
.agents/scripts/linters-local.sh
```

If either named test file is absent at implementation HEAD, add/run the nearest focused shell regression test and document the exact command in the PR.

### Complexity Impact

- Existing shell functions may grow around timeout/fallback handling. Before editing, measure the target function line counts and extract helpers first if projected size exceeds the repo complexity gate.
- Prefer small wrapper/helper functions with explicit `return 0` / `return 1` and `local var="$1"` style. Avoid `eval` for command execution; use Bash arrays to safely handle command parts.

## Acceptance Criteria

- [ ] No implementation uses direct `timeout`; the shared portable `timeout_sec` wrapper or an equivalent portable pattern is used exclusively for bare macOS portability.
- [ ] Slow or stuck `gh api` calls in the person-stats helper are bounded by a wall-clock deadline.
- [ ] Bare macOS/no-coreutils behavior is covered by a regression test or PATH-isolated fake-command test.
- [ ] Cross-repo stats can retain useful partial results or visible timeout markers instead of silently becoming empty output.
- [ ] Dashboard cache metadata does not claim a successful person-stats refresh when both optional stats calls timed out or failed.
- [ ] Relevant focused tests and shell lint pass.

## Context

- Follow-up issue: GH#23761
- Superseded PR: PR #23745
- Prior review decision: request changes because direct `timeout` is not portable, root handling belongs closer to raw `gh api`, and regression tests are missing.
- Related recent work: #23638 / #23605 centralized shared GitHub secondary-rate-limit cooldown for stats/dashboard reads; align with that architecture rather than adding an isolated caller-only wrapper.

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2066: Fix quality sweep — make local SARIF the primary source, retune simplification issue creation

## Origin

- **Created:** 2026-04-14
- **Session:** claude-code:quality-a-grade
- **Created by:** ai-interactive (from C→A qlty audit conversation)
- **Parent task:** none
- **Conversation context:** The daily quality sweep (`stats-functions.sh:_sweep_qlty`) treats the Qlty Cloud badge as the primary grade source and the local SARIF output as secondary. But `qlty.sh/gh/marcusquinn/aidevops/maintainability.svg` currently 404s, so the sweep reports `qlty_grade=UNKNOWN` in the quality dashboard (issue #2632) — while the repo actually sits at C, and the local SARIF has the exact smell count (109). The sweep is blind to its own data.

## What

Rewire `_sweep_qlty` and `_create_simplification_issues` (both in `.agents/scripts/stats-functions.sh`) to:

1. **Local SARIF is the primary truth.** Smell count comes from `qlty smells --all --sarif` directly. Grade is derived from the smell count via a documented mapping (stored in `complexity-thresholds.conf` or a new config). Cloud badge is secondary telemetry — reported if reachable, otherwise omitted, never used as the primary grade.
2. **Retune `_create_simplification_issues`** to be smell-count-driven with throughput-appropriate caps:
   - `min_smells_threshold`: 5 → **3** (catch more medium-density files)
   - `max_issues_per_sweep`: 3 → **5**
   - Total-open cap: 200 → **30** (the goal isn't backlog, it's throughput)
   - Default tier label: `tier:standard` → **`tier:thinking`** (Haiku can't refactor a 72-complexity function)
   - Include per-rule breakdown in the issue body (already computed — just surface it)
3. **Include a smell-count delta in the sweep dashboard.** The sweep state file already records `qlty_smell_count`. Add: compute delta vs previous sweep, render a trend indicator (`↓ -3`, `↑ +7`, `→ 0`) in the dashboard issue.
4. **Fix the dashboard grade rendering.** Issue #2632 shows `Qlty grade UNKNOWN` when grade is unknown; change to render the local-computed grade from (1) above.

## Why

- The current sweep optimises for the wrong signal. The cloud badge lags and sometimes 404s; local SARIF is deterministic, always available, and already computed by the sweep — we just throw the number away and ask a stale cloud endpoint for its opinion.
- The issue-creation caps (3/sweep, 200 open) were set for a world where simplification issues were a trickle. With 50 smelly files, we need throughput not trickle, and the `needs-maintainer-review` gate already rate-limits human work.
- **Tier mismatch is the silent killer.** The current code defaults new simplification issues to whatever the maintainer approves them as, but the auto-label is `tier:standard`. Most smelly files have functions with cyclomatic 25+, which Sonnet handles poorly and Haiku cannot handle at all. Default to `tier:thinking` so the first dispatch attempt succeeds.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? No — `stats-functions.sh` (primary) + complexity-thresholds.conf + tests + possibly a grade mapping config
- [ ] No judgment or design decisions? No — must decide grade bucket thresholds and delta rendering format

**Selected tier:** `tier:thinking`

**Tier rationale:** `stats-functions.sh` is the core sweep module (currently parked at 3164 lines, tier:reasoning by default for any edit per #18768's Phase planning). Every edit here is high-stakes because a bug breaks the daily dashboard update. Opus-tier.

## PR Conventions

Leaf task. PR body: `Resolves #NNN`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/stats-functions.sh:1829-1910` — `_sweep_qlty`: invert SARIF/badge priority
- `EDIT: .agents/scripts/stats-functions.sh:2573-2672` — `_create_simplification_issues`: new thresholds, tier label, per-rule breakdown
- `EDIT: .agents/scripts/stats-functions.sh:2864+` — `_compute_badge_indicator`: accept local grade, render delta
- `EDIT: .agents/scripts/stats-functions.sh:3009+` — dashboard body builder: render delta + local grade
- `EDIT: .agents/configs/complexity-thresholds.conf` — add grade bucket thresholds (`QLTY_GRADE_A_MAX`, `QLTY_GRADE_B_MAX`, etc.)
- `EDIT: .agents/scripts/tests/test-quality-sweep-serialization.sh` — update fixtures for new grade computation

### Implementation Steps

1. **Define smell-count → grade mapping.** Needs user input OR a principled default. Suggested default (proportional to current 109-smell baseline, aiming for A at ≤20):
   - A: 0–20 smells
   - B: 21–45
   - C: 46–90
   - D: 91–150
   - F: 151+
   Store these in `complexity-thresholds.conf` so they are ratchet-able. Document rationale.

2. **Rewrite `_sweep_qlty`** so the flow is:
   - Run local qlty → `$qlty_smell_count`
   - Compute `$qlty_grade` from count via the mapping
   - Fetch cloud badge (best-effort, 5s timeout) → report as `cloud_grade_telemetry` if different from local
   - Return pipe-delimited: `qlty_section|qlty_smell_count|qlty_grade`

3. **Retune `_create_simplification_issues`** — change the four constants, add `--label tier:thinking` to the `gh_create_issue` invocation, inject per-rule breakdown into `_build_simplification_issue_body`.

4. **Add delta tracking.** The sweep state file already records `qlty_smells`. Read the previous sweep's count, compute delta, pass to dashboard builder.

5. **Dashboard rendering.** Issue #2632 currently shows `| Qlty grade | UNKNOWN |`. Update to show:

   ```
   | Qlty grade (local) | C |
   | Qlty smells | 109 ↓ -3 (trend: 7d -12) |
   | Qlty cloud grade | C (badge) |
   ```

6. **Update tests.** `test-quality-sweep-serialization.sh` currently asserts `qlty_grade` == `B`. Make it assert against a computed-from-count value so the test doesn't hard-code.

### Verification

```bash
# Unit test
.agents/scripts/tests/test-quality-sweep-serialization.sh

# Shellcheck clean
shellcheck .agents/scripts/stats-functions.sh

# Local smoke run — should report actual grade, not UNKNOWN
.agents/scripts/stats-functions.sh sweep marcusquinn/aidevops .
```

## Acceptance Criteria

- [ ] Sweep dashboard (issue #2632 or its successor) no longer shows `Qlty grade UNKNOWN`
- [ ] `_sweep_qlty` returns a grade derived from local SARIF count, not the cloud badge
  ```yaml
  verify:
    method: codebase
    pattern: "qlty_grade=.*qlty_smell_count"
    path: ".agents/scripts/stats-functions.sh"
  ```
- [ ] `_create_simplification_issues` caps: `min_smells_threshold=3`, `max_issues_per_sweep=5`, `total_open_cap=30`
  ```yaml
  verify:
    method: bash
    run: "grep -q 'min_smells_threshold=3' .agents/scripts/stats-functions.sh && grep -q 'max_issues_per_sweep=5' .agents/scripts/stats-functions.sh"
  ```
- [ ] Auto-created simplification issues carry `tier:thinking` label by default
  ```yaml
  verify:
    method: codebase
    pattern: "tier:thinking"
    path: ".agents/scripts/stats-functions.sh"
  ```
- [ ] Grade bucket thresholds are in `complexity-thresholds.conf` (ratchet-friendly)
- [ ] Dashboard renders smell-count delta vs previous sweep
- [ ] `test-quality-sweep-serialization.sh` passes
- [ ] Shellcheck clean

## Context & Decisions

- **Why ratchet the grade thresholds in config, not hard-code?** Same reason the shell thresholds are in config — they need to tighten over time as smells decrease. Hard-coding bakes the "C is fine at 80 smells" assumption into the code.
- **Why default new simplification issues to `tier:thinking` and not `tier:reasoning`?** Per user direction 2026-04-14: `tier:thinking` is the canonical opus label going forward (t2073 renames `tier:reasoning` → `tier:thinking` across the framework).

## Relevant Files

- `.agents/scripts/stats-functions.sh:1829` — `_sweep_qlty` (primary target)
- `.agents/scripts/stats-functions.sh:2573` — `_create_simplification_issues`
- `.agents/scripts/stats-functions.sh:2864` — `_compute_badge_indicator`
- `.agents/scripts/tests/test-quality-sweep-serialization.sh:249` — hard-coded `B` grade assertion
- `.agents/configs/complexity-thresholds.conf` — where new grade buckets go

## Dependencies

- **Blocked by:** none
- **Blocks:** t2067 (ratchet needs correct grade reporting)
- **Related:** t2073 (this task depends on the `tier:thinking` label being canonical)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | Read `_sweep_qlty`, `_create_simplification_issues`, tests |
| Implementation | 3h | Refactor + tests |
| Testing | 1h | Unit tests + dashboard smoke |
| **Total** | **~5h** | |

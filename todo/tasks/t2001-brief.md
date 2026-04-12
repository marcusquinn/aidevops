<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2001: Phase 12 — split `run_weekly_complexity_scan()` (298 lines)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** t1962 Phase 12 follow-up (plan §6, candidate #3)
- **Function location:** `.agents/scripts/pulse-simplification.sh:1703` (extracted in Phase 6, t1974 / #18384)

## What

Split `run_weekly_complexity_scan()` into per-language scanner sub-functions. Currently the function inlines shell scanning, markdown scanning, threshold proximity checks, and issue creation into one 298-line block.

Target structure:
1. **`_complexity_scan_languages_iter()`** — top-level loop over languages, dispatches to per-language scanners
2. **`_complexity_scan_lang_shell()`** — shell-specific scan (calls existing `_complexity_scan_collect_violations`, `_complexity_scan_create_issues`)
3. **`_complexity_scan_lang_md()`** — markdown-specific scan (calls existing `_complexity_scan_collect_md_violations`, `_complexity_scan_create_md_issues`)
4. Parent shrinks to setup + result aggregation (<60 lines)

The function already calls per-language helpers — they were extracted in Phase 6. The 298 lines are mostly orchestration glue and threshold-proximity reporting that needs to be peeled out.

## Why

- 298 lines, third-largest post-decomposition.
- Adding a new language scanner today requires understanding the entire 298-line block. Per-language functions make it a 30-line addition.
- The threshold-proximity reporting is a separable concern that could move to its own helper or even into the existing `_check_ci_nesting_threshold_proximity` function.

## Tier

`tier:standard`. Mechanical split with clear seams (per-language already factored at the leaf level — just need to factor at the orchestrator level).

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-simplification.sh:1703-2000` — `run_weekly_complexity_scan()` body
- **VERIFY:** `.agents/scripts/tests/test-pulse-wrapper-complexity-scan.sh` — already validates this cluster end-to-end (10 assertions, all pass after Phase 6)

### Recommended split

1. Read the function. Identify the 4 phases: (a) setup + interval check, (b) shell scan, (c) markdown scan, (d) summary + threshold proximity warning + state push.
2. Extract phases (b) and (c) into language-specific helpers. They already wrap existing leaf functions — this is a one-level-up wrapping.
3. Optionally extract the summary/proximity phase (d) too.
4. Parent becomes a clean orchestrator: `_complexity_scan_check_interval` → `_complexity_scan_lang_shell` → `_complexity_scan_lang_md` → push.

### Verification

```bash
bash -n .agents/scripts/pulse-simplification.sh
.agents/scripts/pulse-wrapper.sh --self-check
bash .agents/scripts/tests/test-pulse-wrapper-complexity-scan.sh  # CRITICAL — must pass
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-simplification.sh
# Sandbox dry-run
```

## Acceptance Criteria

- [ ] `run_weekly_complexity_scan()` reduced to under 80 lines
- [ ] At least 2 new helper functions extracted (one per language family)
- [ ] `test-pulse-wrapper-complexity-scan.sh` passes 10/10 (this test directly exercises this function)
- [ ] All other pulse tests pass
- [ ] `--self-check` clean
- [ ] `shellcheck` no new findings

## Relevant Files

- `.agents/scripts/pulse-simplification.sh:1703`
- `.agents/scripts/tests/test-pulse-wrapper-complexity-scan.sh`
- Existing leaf functions in same module: `_complexity_scan_collect_violations`, `_complexity_scan_collect_md_violations`, `_complexity_scan_create_issues`, `_complexity_scan_create_md_issues`

## Dependencies

- **Related:** t1987 (Phase 12 module split — splits `pulse-simplification.sh` itself into sub-clusters). **Coordination note:** if t1987 lands first and creates `pulse-simplification-scan-shell.sh` / `pulse-simplification-scan-md.sh` sub-modules, the per-language helpers from THIS task should live in those sub-modules. Sequence t1987 before t2001 if possible. If t2001 lands first, t1987 can absorb the new helpers into the right sub-module during its split.

## Estimate

~2h.

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2044: stats-functions decomposition Phase 0 — characterization safety net

## Origin

- **Created:** 2026-04-13, claude-code:interactive
- **Parent task:** t2010 (`todo/tasks/t2010-brief.md`)
- **Plan:** `todo/plans/stats-functions-decomposition.md` §5 (regression safety net) and §6 Phase 0
- **Why this is the entry point:** Plan §6 makes Phase 0 a hard precondition for every extraction phase. No code moves until the safety net catches regressions.

## What

Build the regression safety net required before any extraction PR can land for `.agents/scripts/stats-functions.sh`. This is **Phase 0 of t2010** — no code from `stats-functions.sh` is moved by this task. Only new test infrastructure and new modes on `stats-wrapper.sh` are added.

Three deliverables, all enumerated in `todo/plans/stats-functions-decomposition.md` §5:

1. **Characterization test harness** — `.agents/scripts/tests/test-stats-functions-characterization.sh` (new file). Asserts all 48 currently-defined functions are present after sourcing, plus a small set of pure-function golden outputs to catch semantic drift.
2. **`--self-check` mode** in `.agents/scripts/stats-wrapper.sh` (edit). Sources `stats-functions.sh` and asserts the public entry points and a representative private helper are defined, then exits 0. Exit non-zero on missing functions.
3. **`--dry-run` mode** in `.agents/scripts/stats-wrapper.sh` (edit). Sets `STATS_DRY_RUN=1` and runs the existing main flow with sentinel early-returns added to `update_health_issues` and `run_daily_quality_sweep` (both in `stats-functions.sh`) so the call graph executes end-to-end without making `gh`/`git` calls.

Plus one CI integration:

4. **CI step** that runs both `bash .agents/scripts/stats-wrapper.sh --self-check` and `bash .agents/scripts/tests/test-stats-functions-characterization.sh` on every PR that touches `.agents/scripts/stats-*.sh` or `.agents/scripts/tests/test-stats-*.sh`.

## Why

Plan §5 explains the full rationale. Short version:

- The extraction phases (1-3) move thousands of lines of bash. A typo, a missed function, or an init-order bug is invisible until the cron job runs in production.
- The characterization test gives sub-second feedback that "the surface didn't change", catchable in pre-commit hooks or CI.
- The `--self-check` and `--dry-run` modes give the maintainer a fast smoke test for the cutover steps in Plan §8.5.
- This is exactly the pattern t1962 used (Phase 0 = `test-pulse-wrapper-characterization.sh`, t1963), and it caught zero regressions because it caught them all at PR time.

## Tier

`tier:standard`. This is mechanical implementation work following an existing pattern (`test-pulse-wrapper-characterization.sh`).

### Tier checklist

- [x] **>2 files?** Yes (1 new test file, 1 wrapper edit, 1 CI workflow edit, 1 sentinel pair in stats-functions.sh) — disqualifies `tier:simple`.
- [ ] Skeleton code blocks? No — copy-paste from t1963 precedent and adjust function names.
- [ ] Error/fallback logic to design? No — failures exit non-zero with a message; characterization tests print PASS/FAIL.
- [x] Estimate >1h? Yes (~2-3h) — disqualifies `tier:simple`.
- [ ] >4 acceptance criteria? No (4 below).
- [ ] Judgment keywords? No — every step is mechanical given the plan.

Standard tier (sonnet) is correct.

## How (Approach)

### Files to modify

- **NEW:** `.agents/scripts/tests/test-stats-functions-characterization.sh` — model verbatim on `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` (t1963). Adapt the sandbox setup, the `EXPECTED_FUNCTIONS` list (48 entries, see Plan §3), and the pure-function golden outputs.
- **EDIT:** `.agents/scripts/stats-wrapper.sh` — add `--self-check` and `--dry-run` branches near the top of `main()`, before `check_stats_dedup`. Pattern: see Plan §5.2 and §5.3 code blocks.
- **EDIT:** `.agents/scripts/stats-functions.sh` — add early-return sentinels at the top of `update_health_issues` and `run_daily_quality_sweep` that check `${STATS_DRY_RUN:-}` and return 0 immediately. **These are temporary scaffolding** marked with a comment referencing this task ID and removed after Phase 3 merges.
- **EDIT:** `.github/workflows/framework-validation.yml` (or whichever workflow runs the existing pulse-wrapper characterization test) — add a new step that runs the stats characterization test and `stats-wrapper.sh --self-check` when any `stats-*.sh` file changes.

### Reference patterns

- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` — the canonical model. Study `setup_sandbox()`, the `EXPECTED_FUNCTIONS` array, and the golden assertions.
- `.agents/scripts/pulse-wrapper.sh` — has the equivalent `--self-check` and `--dry-run` modes added during t1963. Use as the structural reference for the new branches in `stats-wrapper.sh`.
- Plan §5 (`todo/plans/stats-functions-decomposition.md`) — has the full code skeletons for all three deliverables. Copy them, fill in the gaps.
- Plan §3.1 — the authoritative list of 48 function names that must populate `EXPECTED_FUNCTIONS`.

### Implementation steps

1. Read Plan §5 in full.
2. Read `test-pulse-wrapper-characterization.sh` as the model.
3. Create `test-stats-functions-characterization.sh` with the sandbox + 48-function existence checks. Run it: `bash .agents/scripts/tests/test-stats-functions-characterization.sh`. Must exit 0.
4. Add `--self-check` to `stats-wrapper.sh`. Run `bash .agents/scripts/stats-wrapper.sh --self-check`. Must print `stats-wrapper self-check OK` and exit 0.
5. Add `STATS_DRY_RUN` sentinels to the two public entry points in `stats-functions.sh`. Add `--dry-run` branch to `stats-wrapper.sh` that sets `STATS_DRY_RUN=1` and calls main. Run `bash .agents/scripts/stats-wrapper.sh --dry-run`. Must complete without any `gh` or `git` calls.
6. Add the CI step.
7. ShellCheck the modified files: `shellcheck .agents/scripts/stats-wrapper.sh .agents/scripts/stats-functions.sh .agents/scripts/tests/test-stats-functions-characterization.sh`.
8. Commit, push, PR.

### Verification

```bash
# Local
bash .agents/scripts/tests/test-stats-functions-characterization.sh           # exit 0, prints PASS for all 48 functions
bash .agents/scripts/stats-wrapper.sh --self-check                            # exit 0
bash .agents/scripts/stats-wrapper.sh --dry-run                               # exit 0, no gh/git calls
shellcheck .agents/scripts/stats-wrapper.sh .agents/scripts/stats-functions.sh
shellcheck .agents/scripts/tests/test-stats-functions-characterization.sh

# CI
# The new framework-validation step must run and pass on the PR.
```

## Acceptance Criteria

- [ ] `.agents/scripts/tests/test-stats-functions-characterization.sh` exists and passes against the current monolithic `stats-functions.sh`. Asserts all 48 functions from Plan §3.1 are defined.
- [ ] `bash .agents/scripts/stats-wrapper.sh --self-check` exits 0 and prints a success line.
- [ ] `bash .agents/scripts/stats-wrapper.sh --dry-run` exits 0 and makes zero `gh` or `git` calls (verified by stub or strace if needed).
- [ ] CI workflow runs both checks on every PR touching `stats-*.sh`. At least one new step in `.github/workflows/framework-validation.yml` (or equivalent).
- [ ] ShellCheck clean on all modified files.
- [ ] PR body cites this brief and Plan §5 / §6 Phase 0.

## Relevant Files

- `todo/plans/stats-functions-decomposition.md` — the plan (read §5 and §6 Phase 0 in full)
- `.agents/scripts/stats-functions.sh` — target of the characterization test
- `.agents/scripts/stats-wrapper.sh` — gets `--self-check` and `--dry-run`
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` — the model to copy
- `.agents/scripts/tests/test-stats-functions-characterization.sh` — NEW, this task creates it

## Dependencies

- **Blocked by:** none (this is the entry point for the t2010 decomposition tree)
- **Blocks:** Phase 1 (stats-shared extraction), Phase 2 (stats-quality-sweep extraction), Phase 3 (stats-health-dashboard extraction)
- **Parent:** t2010

## Estimate

~2-3h. Mechanical work copying t1963 patterns into the stats namespace.

## Out of scope

- Any code movement out of `stats-functions.sh` (Phases 1-3 own that)
- Any function-internal refactoring
- Removal of the dry-run sentinels (deferred until Phase 3 merges and the orchestrator residual is final)

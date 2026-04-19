# t2390: fix(stats): export AIDEVOPS_HEADLESS in stats-wrapper.sh main() to unblock quality-debt dispatch

## Session origin

Interactive, marcusquinn, 2026-04-19. Picked up #19913 after maintainer crypto-approval.

## What

Add `export AIDEVOPS_HEADLESS=true` at the top of `stats-wrapper.sh main()`, before the `--self-check` dispatch. Add a sibling regression test at `.agents/scripts/tests/test-stats-wrapper-headless-export.sh` modelled on the existing `test-pulse-wrapper-headless-export.sh`.

## Why

Direct regression of GH#18670. PR #18676 added the headless export to `pulse-wrapper.sh main()` but did not extend it to `stats-wrapper.sh`, which is a second `gh_create_issue` entry point driven by a separate scheduler (15-min `aidevops-stats-wrapper.timer` / launchd plist).

Under the timer, `detect_session_origin()` at `shared-constants.sh:834` falls through to the default `interactive`, so every `quality-debt` issue created by `_sweep_review_scanner → quality-feedback-helper.sh → _create_new_quality_debt_issue → gh_create_issue` lands with `origin:interactive` + auto-assigned to the runner. The GH#18352 dispatch-dedup guard then blocks the issue indefinitely, stranding every `quality-debt` sweep on every machine running the stats wrapper.

The reporter (robstiles) provided direct log evidence from 2026-04-19 14:52-14:55Z showing 5 stuck issues on a managed private repo with the exact label combination. Hotfix applied to their local install; upstream fix is this change.

Affects every user on every machine running the stats wrapper, which is the primary productivity goal: "full concurrency worker & pulse productivity for all users and machines".

## How

**EDIT: `.agents/scripts/stats-wrapper.sh` line 150-158** — insert the export block immediately after `main() {` and before the `--self-check` comment header.

Exact replacement (verbatim from the maintainer-approved issue #19913 Solution Evaluation):

```bash
main() {
    # GH#19913: declare this process as headless BEFORE anything else runs
    # so every child shell stage sees AIDEVOPS_HEADLESS and
    # detect_session_origin() returns "worker". Mirrors the GH#18670 fix in
    # pulse-wrapper.sh:1369. Without this, _sweep_review_scanner ->
    # quality-feedback-helper.sh -> _create_new_quality_debt_issue ->
    # gh_create_issue -> session_origin_label() defaults to
    # "origin:interactive" and _gh_wrapper_auto_assignee assigns the
    # runner, which trips GH#18352's dispatch-dedup guard and strands every
    # quality-debt issue the 15-min stats sweep creates. Scoped to main()
    # so callers sourcing stats-wrapper.sh for testing do not inherit the
    # env var (same scoping guarantee as pulse-wrapper.sh).
    export AIDEVOPS_HEADLESS=true

    #######################################
    # --self-check mode (t2044 Phase 0 -- plan section 5.2)
    ...
```

**NEW: `.agents/scripts/tests/test-stats-wrapper-headless-export.sh`** — mirror `.agents/scripts/tests/test-pulse-wrapper-headless-export.sh` with 4 behavioural tests:

1. Export line present at top of `main()` (before `--self-check` dispatch)
2. `detect_session_origin()` returns `"worker"` when `AIDEVOPS_HEADLESS=true`
3. Export is inside `main()` (indented), not at top level — scoping guarantee
4. Export precedes the `--self-check` dispatch so CI self-checks run headless

## Acceptance

1. `stats-wrapper.sh main()` exports `AIDEVOPS_HEADLESS=true` before any other statement.
2. `stats-wrapper.sh --self-check` still passes.
3. `test-stats-wrapper-headless-export.sh` passes (4 tests).
4. Shellcheck clean on both edited and new files.

## Context

- **Issue**: #19913 (crypto-approved by marcusquinn 2026-04-19T16:13:14Z)
- **Reference pattern**: `.agents/scripts/pulse-wrapper.sh:1360-1369` (GH#18670 fix)
- **Reference test**: `.agents/scripts/tests/test-pulse-wrapper-headless-export.sh`
- **Call chain**: `stats-wrapper.sh main → run_daily_quality_sweep → _sweep_review_scanner → quality-feedback-helper.sh → _create_new_quality_debt_issue → gh_create_issue → session_origin_label → detect_session_origin`
- **Dedup guard**: `.agents/scripts/dispatch-dedup-helper.sh is-assigned` Layer 6 (GH#18352)
- **Scope**: `.agents/scripts/stats-wrapper.sh` (1 file edited), `.agents/scripts/tests/test-stats-wrapper-headless-export.sh` (1 file added). No changes to schedulers, quality-feedback-issues-lib.sh, shared-constants.sh, or dispatch-dedup logic.
- **Not affected**: `shellcheck-wrapper.sh` — wraps the `shellcheck` binary with RSS watchdog and rate limiting, does not call `gh_create_issue` (confirmed by reporter).

## Tier

`tier:simple` — 1 file edited, 1 file added, exact oldString/newString derivable from issue body, 4 acceptance criteria, no judgment keywords, target files under 500 lines.

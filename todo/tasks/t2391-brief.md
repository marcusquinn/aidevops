<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2391: fix(issue-sync): range-syntax PR title guard for TODO auto-complete

## Origin

- **Created:** 2026-04-19
- **Session:** Claude Code (interactive continuation, acting on open-issue triage)
- **Observation:** While auditing the 36-issue backlog for concurrency/productivity blockers, revisited GH#19825 (t2369 in the issue title). The filing session's memory entry (`mem_20260419020126_e137cd2a`) confirmed that PR #19814 — titled `t2259..t2264: plan framework observations` — auto-marked t2259 `[x]` in TODO.md despite being a planning-only PR filing briefs for six tasks. The reverting PR #19818 restored the state, but the underlying guard was never added.

## What

Add a range-syntax PR title guard to the `.github/workflows/issue-sync.yml` `sync-on-pr-merge` job so that titles like `tNNN..tNNN: ...` or `tNNN, tNNN: ...` skip the TODO auto-complete step entirely, regardless of body keywords.

## Why

The canonical invariant — `[x] tNNN` in TODO.md means "the code for tNNN shipped" — is violated on every multi-task planning PR whose title starts with a task-ID range. PR #19814 is the existence proof. t2252 (PR #19819) added the `For/Ref`-only body guard, closing part of the gap; t2391 closes the remaining gap where a range-syntax title ships with a closing keyword in the body (Case D in the acceptance criteria).

The direct consequence of leaving this open is trust erosion on the audit trail: operators who see a `[x]` mark in TODO.md can no longer rely on it meaning the task is done. This compounds across the multi-machine, multi-user pulse the user is trying to stabilise — every operator has to manually audit `[x]` marks against PR diffs.

## How

### Issue-filing session's premise was partly wrong on files

The issue body names `.agents/scripts/pulse-merge.sh` and `.agents/scripts/task-complete-helper.sh` as edit sites. Neither is correct:

- `pulse-merge.sh` has **0 hits** for auto-complete logic (verified via `rg 'completed:|mark.*complete|\[x\]' .agents/scripts/pulse-merge.sh`).
- `task-complete-helper.sh` is a user-facing helper that takes an explicit `task_id` argument — it's invoked manually, not on PR merge.

The actual fix site is `.github/workflows/issue-sync.yml`. This is a worker-triage Outcome B case: premise partly falsified on files, but the bug is real and the corrected fix site is obvious. Proceeded to implement.

### Edits

1. **Extract step** (lines 386-399): add `RANGE_SYNTAX` detection after `FOR_REF_ISSUES`. Two patterns: `^t[0-9]+\.\.t[0-9]+` (range) and `^t[0-9]+,[[:space:]]*t[0-9]+` (comma-separated). Emit to `GITHUB_OUTPUT`.
2. **Update step** (lines 673-680): add `RANGE_SYNTAX` env from `steps.extract.outputs.range_syntax`.
3. **Update step guard** (lines 695-710): add early exit when `RANGE_SYNTAX=true`, BEFORE the existing t2252 For/Ref-only guard. Order matters — Case D (range-syntax title + body `Closes #NNN`) has `LINKED_ISSUES` populated, which would fall through the t2252 guard and reach the mark-complete path.

### Regression test

`.agents/scripts/tests/test-pulse-auto-complete-keywords.sh` (10 tests):

- **Static inspection (3)**: asserts the range-syntax regex exists in the extract step, the `RANGE_SYNTAX` env + guard exist in the update step, and the range guard precedes the for/ref guard in source order.
- **Behavioural (7)**: reimplements the classification logic from the workflow as a pure bash function (`classify_pr`), then asserts the five cases from the issue body (A baseline, B for/ref, C range+for, D range+closes belt-and-braces, E single-task-ID) plus a comma-range edge case (F) and a real-world replay of PR #19814.

The static-inspection tests keep the behavioural re-implementation honest: if someone changes the workflow regex without updating the test, the static checks fail.

## Tier

`tier:standard` — small logic change but blast radius is every merged PR on every repo using this workflow. Needs careful regression testing.

## Acceptance

- [x] Range-syntax PR titles (`tNNN..tNNN`, `tNNN, tNNN`) suppress TODO auto-complete regardless of body keywords.
- [x] Existing t2252 For/Ref guard continues to fire (Case B still skips).
- [x] Single-task-ID titles with `Resolves`/`Closes`/`Fixes` still mark complete (Cases A, E still proceed).
- [x] Regression test `.agents/scripts/tests/test-pulse-auto-complete-keywords.sh` covers cases A-F plus PR #19814 replay and passes (10/10).
- [x] Guard order asserted: range-syntax fires before for/ref.

## Context

- **Direct evidence:** PR #19814 merged 2026-04-19 00:47 UTC, auto-marked t2259 `[x]`. Reverted via PR #19818.
- **Memory:** `mem_20260419020126_e137cd2a`.
- **Related:**
  - PR #19814 (batch planning that triggered the bug)
  - PR #19818 (the revert)
  - t2219 (sibling fix for the issue status:done path — PR #19820)
  - t2252 (sibling fix for the TODO For/Ref-only path — PR #19819)
- **Out of scope:** the `Find issue by task ID (fallback)` step (line 403) that applies `status:done` to issues via title-fallback. Its existing parent-task (t2137) and For/Ref (t2219) guards are sufficient for the cases specified in the issue. A range-syntax guard there could be added as a followup if needed, but none of the 5 issue cases exercise that path.

## Relevant files

- `.github/workflows/issue-sync.yml` — primary edit site (extract step + update step guard + env)
- `.agents/scripts/tests/test-pulse-auto-complete-keywords.sh` — NEW regression test

## Verification evidence

Test run (in worktree, pre-commit):

```
Static inspection:
  PASS extract step: range-syntax regex + GITHUB_OUTPUT present
  PASS update step: RANGE_SYNTAX env + guard present
  PASS guard order: range-syntax (line 725) precedes for/ref (line 740)

Behavioural cases (A-F + real-world replay):
  PASS Case A: MARK_COMPLETE
  PASS Case B: SKIP_FOR_REF
  PASS Case C: SKIP_RANGE
  PASS Case D: SKIP_RANGE
  PASS Case E: MARK_COMPLETE
  PASS Case F (comma range): SKIP_RANGE
  PASS PR #19814 replay: new logic correctly skips (was mark-complete before t2391)

Ran 10 tests, 0 failed.
```

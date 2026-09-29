<!-- aidevops:brief-schema=v2 -->

# t18551: Planning publication: defer not-yet-landed tasks instead of failing every main Issue Sync; repair stranded publication:pending issues

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** While landing planning PR #32961 (t18538), Issue Sync run 36511706459 on merge SHA `185b01a380` reconciled t18538/#32960 correctly but still failed the job. The failure came from five unrelated `publication:pending` issues. The maintainer asked for this to be captured for auto-dispatch.

## What

1. Make `planning-publication-reconcile.sh reconcile` distinguish between:
   - **reconciled**: the task was published.
   - **deferred**: the task line is absent from the exact default-branch snapshot and the issue is younger than a staleness window. This is the documented PUBLISHING state, because its planning PR has not landed.
   - **stale/failed**: the task is absent past the window, or its task line exists but the ref or brief is invalid or the brief is not worker-ready. This is PUBLICATION_FAILED.

   Only stale/failed issues make the command exit non-zero. Every run prints one machine-readable summary line.
2. Repair the three currently stranded issues so they publish on the next default-branch sync.

## Why

`cmd_reconcile` (`.agents/scripts/planning-publication-reconcile.sh:271-303`) iterates every open `publication:pending` issue in the repo. It increments `failed` on any `_publication_reconcile_one` failure (L300), so one unrelated pending task fails the Issue Sync job for every push to `main`. The workflow step has `continue-on-error: true` (`.github/workflows/issue-sync-reusable.yml:295-305`), but `Report planning publication failure` (L334-337) then fails the job. The result is a permanent red signal that hides real publication failures.

`_publication_validate_mapping` (L165-172) returns the same failure for "task absent" and "brief missing", even though `.agents/reference/planning-publication-lifecycle.md:65-93` defines PUBLISHING (planning PR open) as a normal, expected state.

Evidence from run 36511706459, step `Reconcile pending planning publication`:

- `t18538/#32960: planning publication reconciled`
- `t18539/#32964`, `t18537/#32955`: validation failed. Both were in flight; their implementation PRs #32970 and #32962 have since merged and the issues are no longer pending.
- `t18512/#32749`, `t18504/#32714`, `t18497/#32692`: validation failed, and all three are still open with `publication:pending` about 36h later. On `origin/main` at `3c4b9a739e`:
  - `t18497` and `t18504` have TODO.md lines with `#auto-dispatch` and `ref:GH#…`, but no `todo/tasks/t18497-brief.md` or `todo/tasks/t18504-brief.md`. Neither brief was ever committed: `git log origin/main -S t18504 -- todo/tasks` is empty.
  - `t18512` has no TODO.md line and no brief. The line is restored in this task's planning PR, so the worker only needs the brief.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: one shell script's control flow plus three brief files derived from existing issue bodies. Not `tier:simple`, because the classification changes a fail-closed publication gate and must keep every intermediate state non-dispatchable.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/planning-publication-reconcile.sh:165-172,189-195,271-303`:
  - Make `_publication_validate_mapping` return a distinct code (e.g. `3`) when the task line is absent.
  - Make `_publication_reconcile_one` propagate that code with a specific warning.
  - In `cmd_reconcile`, request `createdAt` from `gh issue list` and classify each issue as reconciled, deferred or stale/failed. Print `PUBLICATION_RECONCILE_SUMMARY reconciled=N deferred=N stale=N failed=N`, and exit non-zero only when `stale+failed > 0`.
- `EDIT: .agents/scripts/tests/test-planning-publication-reconcile.sh`: add cases proving that an absent-and-young task is deferred and exits 0, an absent-and-stale task fails, and a present task with a missing brief still fails.
- `EDIT: .agents/reference/planning-publication-lifecycle.md:65-93`: in the state model, state that PUBLISHING issues are deferred, not failed, until `AIDEVOPS_PUBLICATION_STALE_HOURS`.
- `NEW: todo/tasks/t18497-brief.md`, `NEW: todo/tasks/t18504-brief.md`, `NEW: todo/tasks/t18512-brief.md`: worker-ready v2 briefs derived from the bodies of issues #32692, #32714 and #32749 (`gh issue view <N> --json body`). Model them on `todo/tasks/t18538-brief.md`. Each must pass `verify-brief-helper.sh check-readiness`.
  - **t18497:** PR #32963 already made the two discovery fetches shallow (`.agents/scripts/claim-task-id-counter.sh:499-521`). Narrow the brief to the remaining items from the issue: the other fetch call sites (L839, L894, L1103-1112, L1192-1211, L1281-1315) and the `CAS_HTTPS_TIMEOUT_S` hint in the `COUNTER_BRANCH_DISCOVERY_ERROR` text (L510). If nothing material remains, write a minimal brief and instead close #32692 with a comment citing #32963. `sweep-closed` then clears the pending label because the ref exists on the default branch.

### Complete Write Surface

- **Callers/readers:**
  - `.github/workflows/issue-sync-reusable.yml:295-305` uses the exit code via `steps.planning-publication.outcome`.
  - `.agents/scripts/full-loop-helper-merge.sh:1692-1713` prints `Planning publication reconcile deferred` on non-zero and emits `PLANNING_RECONCILE_NEXT`.
  - `.agents/scripts/pulse-issue-reconcile.sh:1266-1284` (`_repair_pending_planning_publications`) ignores the exit code (`|| true`) and appends output to `LOGFILE`.
  - `.agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh:926` asserts the `PLANNING_RECONCILE_NEXT` text.
  - `.agents/scripts/tests/test-planning-publication-lifecycle.sh:11` sources the reconciler.
- **Writers/mutation paths:** label edits go only through `gh_issue_edit_safe` inside `_publication_reconcile_one` (L213-258). They are audited by caller path in `.agents/scripts/shared-gh-wrappers-safe-edit.sh:322-323` and `.agents/scripts/gh-audit-anomaly-filter.jq:121`. Deferral must perform no edits.
- **Existing verification/tests:** `.agents/scripts/tests/test-planning-publication-reconcile.sh` (243 lines; it stubs `gh`, `gh_issue_edit_safe` and `_publication_validate_mapping` at L95-126), `.agents/scripts/tests/test-planning-publication-lifecycle.sh`, `.agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh`, and `.agents/scripts/tests/test-gh-audit-anomaly-expected-transitions.sh`.
- **Schemas/config:** a new env tunable `AIDEVOPS_PUBLICATION_STALE_HOURS` (default 24, validated `^[1-9][0-9]*$`), matching `AIDEVOPS_PUBLICATION_RECONCILE_LIMIT` at L22. `gh issue list --json` gains `createdAt`.
- **Generated/deployed mirrors:** the deployed copy `~/.aidevops/agents/scripts/planning-publication-reconcile.sh` is refreshed by `setup.sh` and release deploy. The workflow runs the checked-out `__aidevops/` copy, so there are no generated files.
- **Migrations/backfills:** the only data repair is backfilling `todo/tasks/t18497-brief.md`, `todo/tasks/t18504-brief.md` and `todo/tasks/t18512-brief.md`; there is no schema migration. The briefs land on the default branch in this PR, and the post-merge Issue Sync run reconciles #32714, #32749 and #32692 automatically.
- **Cleanup/rollback paths:** revert the PR. Old `.agents/scripts/planning-publication-reconcile.sh` treats every absent task as a failure again (the status quo), and the added `todo/tasks/*-brief.md` files remain valid planning files.

### Implementation Steps

1. In `_publication_validate_mapping`, return `3` when `_publication_task_line` fails; keep returning `1` for a ref mismatch or a missing or symlinked brief.
2. In `_publication_reconcile_one`, capture the rc of `_publication_validate_mapping`. On `3`, print `"${task_id}/#${issue_num}: task absent from default-branch snapshot; publication deferred"` and `return 3`. Keep the existing warning for rc `1`.
3. In `cmd_reconcile`, add `createdAt` to `--json` and emit `number,title,createdAt` as TSV. On rc `3`, compute age in hours from `createdAt`, using portable epoch parsing (`date -u -d` / `date -j -f` fallbacks; see `reference/bash-compat.md`). Count the issue as `deferred` when age < `AIDEVOPS_PUBLICATION_STALE_HOURS`, otherwise as `stale`, and print a `::warning::`-compatible line naming the task and issue when `GITHUB_ACTIONS=true`. If `createdAt` cannot be parsed, count the issue as `stale`, so parse failures fail closed.
4. Print the summary line and `[[ $((stale + failed)) -eq 0 ]]`. Keep the untitled-task branch (L298) counted as `failed`.
5. Write the three briefs, then run `verify-brief-helper.sh check-readiness` on each.
6. Update the lifecycle state model text and run the verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** deferral performs no GitHub mutation, so it cannot race `_publication_reconcile_one`'s edit ordering. `publication:pending` stays the last label removed (L243-246).
- **Migration/rollback:** no persistent state. Rollback restores the old strict exit code.
- **Mixed-version/backward compatibility:**
  - `full-loop-helper-merge.sh` treats any non-zero as deferred and `pulse-issue-reconcile.sh` ignores the exit code, so new rc values are safe for both callers.
  - `cmd_reconcile` still returns only 0 or 1 externally. The rc `3` is internal to the per-issue helper.
  - The `--task` filter (L299) behaves the same.
- **Idempotency/retry:** deferred issues are retried by every later default-branch sync and by the pulse repair (`pulse-issue-reconcile.sh:1277`).
- **Partial failure/recovery:** a deferred issue keeps `publication:pending`, so it stays non-dispatchable. A task that is present but invalid still fails the run, so real failures stay visible. Only absence inside the window is softened.
- **Dispatch fence:** all three stranded issues also carry `status:available`, applied at creation (for #32692, timeline shows it at 2026-09-27T23:33:13Z by the session token), which contradicts `planning-publication-lifecycle.md:74-76`. Verify, without changing it in this PR, that pulse dispatch candidate selection excludes `publication:pending` regardless of `status:available`. If it does not, file a separate bug with evidence.

### Complexity Impact

- **Target function:** `cmd_reconcile` in `.agents/scripts/planning-publication-reconcile.sh`
- **Current line count:** 33 lines (L271-303; threshold: 100 lines for function-complexity)
- **Estimated growth:** about +20 lines (classification, age parse, summary)
- **Projected post-change:** about 53 lines (53% of threshold)
- **Action required:** extract `_publication_issue_age_hours <createdAt>` as a helper to keep the date portability code isolated; no other extraction is needed.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/planning-publication-reconcile.sh
bash .agents/scripts/tests/test-planning-publication-reconcile.sh
bash .agents/scripts/tests/test-planning-publication-lifecycle.sh
bash .agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh
bash .agents/scripts/tests/test-gh-audit-anomaly-expected-transitions.sh
for t in t18497 t18504 t18512; do .agents/scripts/verify-brief-helper.sh check-readiness "todo/tasks/${t}-brief.md"; done
```

- **Surface mapping:**
  - `shellcheck` plus `test-planning-publication-reconcile.sh` cover the classification and exit code in `planning-publication-reconcile.sh` (idempotency and partial-failure hazards).
  - `test-planning-publication-lifecycle.sh` proves the PUBLISHING/PUBLISHED transitions are unchanged.
  - `test-full-loop-merge-worktree-cleanup.sh` covers the `full-loop-helper-merge.sh` caller contract (mixed-version hazard).
  - `test-gh-audit-anomaly-expected-transitions.sh` proves the audited mutation path is unchanged (concurrency hazard).
  - `check-readiness` proves the three backfilled briefs make their tasks publishable.
  - Runtime proof is the post-merge Issue Sync run: its reconcile step prints the summary line and reconciles #32714, #32749 and #32692 (or #32692 is closed as superseded).
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:**

- Do not remove `publication:pending` from any issue whose task is absent from the default-branch snapshot.
- Do not relax `_publication_dispatch_ready` or brief readiness for tasks that are present.
- Do not change the `.github/workflows/issue-sync-reusable.yml` step structure.
- Never allocate replacement task IDs for the stranded tasks; the lifecycle doc forbids it.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/planning-publication-reconcile.sh`
- `.agents/scripts/tests/test-planning-publication-reconcile.sh`
- `.agents/reference/planning-publication-lifecycle.md`
- `todo/tasks/t18497-brief.md`
- `todo/tasks/t18504-brief.md`
- `todo/tasks/t18512-brief.md`

## Acceptance Criteria

- [ ] A pending issue whose task is absent from the snapshot and younger than `AIDEVOPS_PUBLICATION_STALE_HOURS` is counted as `deferred`. It receives no label edits, and on its own it leaves `reconcile` exiting 0.

  ```yaml
  verify:
    method: codebase
    pattern: "PUBLICATION_RECONCILE_SUMMARY"
    path: ".agents/scripts/planning-publication-reconcile.sh"
  ```

- [ ] An absent task past the stale window, a present task with a missing brief, or a present auto-dispatch task with a non-ready brief each still make `reconcile` exit non-zero and keep `publication:pending`.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-planning-publication-reconcile.sh"
  ```

- [ ] `todo/tasks/t18497-brief.md`, `todo/tasks/t18504-brief.md` and `todo/tasks/t18512-brief.md` exist and pass `verify-brief-helper.sh check-readiness`. Alternatively, #32692 is closed with a comment citing #32963 and only the other two briefs are required.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18504-brief.md"
  ```

- [ ] Negative/regression: callers are unchanged. `full-loop-helper-merge.sh` and `pulse-issue-reconcile.sh` need no edits and their tests pass.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh"
  ```

- [ ] Changed-file lint is clean: `shellcheck .agents/scripts/planning-publication-reconcile.sh`

## Context & Decisions

- The default window is 24h. Planning PRs normally land within minutes to a few hours, and the stranded issues had waited about 36h with no signal other than a red job that looked like noise.
- Stale failures stay loud rather than becoming warnings. A stranded publication needs an operator or worker, and silent deferral would hide it forever.
- Reconciliation is still repo-wide rather than scoped to the tasks touched by the pushed SHA. That keeps the pulse and workflow retry paths able to heal older pending issues.

## Relevant Files

- `.agents/scripts/planning-publication-reconcile.sh:165-303`: validation, per-issue reconcile and the loop
- `.github/workflows/issue-sync-reusable.yml:295-337`: reconcile step and failure report
- `.agents/reference/planning-publication-lifecycle.md:65-93`: state model
- `.agents/scripts/pulse-issue-reconcile.sh:1266-1284`: pulse repair caller

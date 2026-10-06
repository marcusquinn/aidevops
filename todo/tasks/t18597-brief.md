## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session; implementing now)
- **Evidence source:** issue-sync run `37495532410` log, `.github/workflows/issue-sync-reusable.yml`

## What

One task whose issue creation fails in the `Push new tasks as issues` step must not skip
the rest of the TODO.md sync job. Planning publication reconcile, ref pull-back and
TODO.md publication must still run for every other task, and the run must still end
red so the failing task stays visible.

## Why

Throughput: since 2026-10-04 one deferred task (t18583) failed issue creation on every
push to `main` (privacy guard blocked a placeholder path in its brief). The push step
exits 1, and the following steps use the implicit `success()` condition, so they were
skipped on every run:

- `Reconcile pending planning publication` (line 295) — newly filed tasks stayed
  `publication:pending` and were never dispatched unless their planning PR happened to be
  merged through `full-loop-helper.sh merge`, which reconciles locally. Observed: #33794
  stayed `publication:pending` after planning PR #33795 merged (run `37495532410`).
- `Pull any missing refs back to TODO.md` / `Publish TODO.md updates` — refs for issues
  created successfully in the same run would not be written back.
- `Enrich plan-linked issues`, `Show sync status`.

Run log: `Push complete: 0 created, 0 skipped, 1 failed` → `##[error]Process completed with exit code 1`.

## Tier

`tier:standard` — single workflow file, clear pattern already used by the relationship and publication steps.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/issue-sync-reusable.yml:271-281` — give the push step `id: push-tasks` and `continue-on-error: true` so later steps keep their implicit `success()` gating.
- `EDIT: .github/workflows/issue-sync-reusable.yml` (end of the `sync` job) — add `Report task issue-creation failure` with `if: steps.push-tasks.outcome == 'failure'` that emits `::error::` and `exit 1`, preserving a red run.

### Complete Write Surface

- **Callers/readers:** `.github/workflows/issue-sync.yml` (local `uses:`) and downstream repos via `issue-sync-reusable.yml@main`.
- **Writers/mutation paths:** unchanged commands; only step gating changes.
- **Existing verification/tests:** `tests/test-issue-sync-push-failures.sh`, `tests/test-planning-publication-reconcile.sh` (structural workflow assertions).
- **Schemas/config:** none. **Generated/deployed mirrors:** none. **Migrations:** none.
- **Cleanup/rollback paths:** revert the workflow edit.

### Hazards and Compatibility

- **Partial failure/recovery:** reconcile only publishes tasks with valid exact-SHA mapping and brief; a failed task keeps no ref and stays unpublished. Pulling refs after a partial push reduces duplicate-creation risk on the next run.
- **Concurrency/idempotency:** all downstream steps are already idempotent and run on successful pushes today.
- **Mixed-version:** downstream repos pick up the change from `@main` on their next run.

### Verification Before Dispatch

```bash
actionlint .github/workflows/issue-sync-reusable.yml
bash .agents/scripts/tests/test-issue-sync-push-failures.sh
bash .agents/scripts/tests/test-planning-publication-reconcile.sh
```

- **Surface mapping:** actionlint validates expressions/step ids; suites keep existing workflow structure assertions green. Runtime proof: next push-triggered issue-sync run.
- **Broad verification trigger:** Not required.

### Files Scope

- `.github/workflows/issue-sync-reusable.yml`

## Acceptance Criteria

- [ ] Positive: when the push step exits non-zero, `Reconcile pending planning publication`, `Pull any missing refs back to TODO.md` and `Publish TODO.md updates` still run.
- [ ] Positive: the job still ends failed with an `::error::` naming the issue-creation failure.
- [ ] Regression: a push rc of 0 or 2 (relationships pending) behaves as before; author-skip still skips every step.
- [ ] All verification commands pass.

## Context & Decisions

- Chosen: `continue-on-error` + terminal report step (keeps downstream `success()` gating and red visibility) over adding `always()` to each downstream step.
- Root data fix for t18583 (placeholder path in its brief) ships in the same PR.

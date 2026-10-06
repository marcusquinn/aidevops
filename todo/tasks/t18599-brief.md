## Origin

- **Created:** 2026-10-06, interactive throughput review (maintainer session; implementing now)
- **Evidence source:** issue-sync run `37507133807` (PR #33815 merge), issue label events on #33810/#33811

## What

When the CI planning-publication reconcile and the local merge-time reconcile
(`full-loop-helper.sh merge`) run at the same time, the loser must treat an issue whose
`publication:pending` label was already removed as reconciled, not as a silent failure.

## Why

Run `37507133807` reported `PUBLICATION_RECONCILE_SUMMARY reconciled=0 ... failed=1` with
no warning and failed the job, yet no issue was left pending. Label events show the local
reconcile removed `publication:pending` from #33811 at 17:54:33Z and #33810 at 17:54:50Z,
while CI listed pending issues at about 17:54:48Z. CI then hit
`_publication_issue_has_labels "$issue_json" "$PUBLICATION_PENDING_LABEL" || return 1`
(`planning-publication-reconcile.sh:271`, and the post-mutation re-check at line 298),
which returns 1 without a message. Every planning merge through `full-loop-helper.sh` can
race like this, turning issue-sync red and hiding real failures.

## Tier

`tier:standard` — one helper, two guarded checks.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/planning-publication-reconcile.sh:266-298` — add `_publication_concurrently_reconciled` (pending label absent on a fresh issue view) and use it at the pre-mutation and post-mutation pending checks: print an info line and return 0.
- Silent `return 1` at those two points becomes the concurrent-success path; other failure paths unchanged.

### Complete Write Surface

- **Callers/readers:** `cmd_reconcile` (CI step `Reconcile pending planning publication`, `full-loop-helper.sh merge`, manual `reconcile --task`).
- **Writers/mutation paths:** no new writes; fewer redundant label edits.
- **Existing verification/tests:** `tests/test-planning-publication-reconcile.sh`, `tests/test-planning-publication-lifecycle.sh`.
- **Schemas/config/mirrors/migrations:** none. **Rollback:** revert.

### Hazards and Compatibility

- **Concurrency:** `publication:pending` removal is the reconciler's final mutation (comment at line 308), so its absence means another reconciler finished every earlier step.
- **Partial failure:** issues whose pending label is still present keep the existing fail-closed checks.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-planning-publication-reconcile.sh
bash .agents/scripts/tests/test-planning-publication-lifecycle.sh
shellcheck .agents/scripts/planning-publication-reconcile.sh
```

- **Broad verification trigger:** Not required.

### Files Scope

- `.agents/scripts/planning-publication-reconcile.sh`

## Acceptance Criteria

- [ ] Positive: an issue listed as pending whose label is gone by the time it is processed counts as reconciled and logs `already reconciled concurrently`.
- [ ] Regression: an issue that still has `publication:pending` and fails validation still counts as failed.
- [ ] All verification commands pass.

## What

Make the planning-publication gap visible at the point of failure: (1) when `claim-task-id.sh --brief-file` runs from a canonical checkout, the stderr advisory must name every artifact the default branch needs (TODO line **and** `todo/tasks/<task_id>-brief.md`) plus the publish command; (2) `planning-publication-reconcile.sh` must say which validation failed (task line, `ref:GH#N` mismatch, or missing/invalid brief) instead of one combined warning.

## Why

Observed in t18614 (GH#33978): an interactive session ran `claim-task-id.sh --brief-file <tmp brief>` from the canonical checkout. The issue was created with the brief inlined, and stderr said only `TODO.md was not changed in canonical checkout; add this line in a linked worktree: <line>`. The session added the TODO line in an unrelated PR (#33977); after merge the reconciler printed `t18614/#33978: canonical task, ref, or brief validation failed; retaining publication:pending` with no hint that `todo/tasks/t18614-brief.md` was the missing piece. Diagnosing it required reading `_publication_validate_mapping` and a second planning PR (#33980). Either message naming the brief would have put it in the first PR.

## Tier

tier:standard — two message/return-code changes in known functions; no contract change.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Canonical advisory: .agents/scripts/claim-task-id-issue.sh:831-838 (_ensure_todo_entry_written)
#    TASK_BRIEF_FILE is a global set by claim-task-id.sh:369-370 and visible here.
# 2. Reconcile mapping: .agents/scripts/planning-publication-reconcile.sh:242-249 (_publication_validate_mapping)
#    returns 3 = task absent (deferred), 1 = everything else; caller warns at :281-287.
# 3. Gotcha: test-claim-task-id-no-orphan.sh:605-614 greps the literal
#    'TODO.md was not changed in canonical checkout.*>&2' — keep that phrase and stderr redirection.
```

### Files to Modify

- `EDIT: .agents/scripts/claim-task-id-issue.sh:831-838` — after the existing advisory, when `${TASK_BRIEF_FILE:-}` is non-empty also print to stderr: `copy the brief to todo/tasks/<task_id>-brief.md in the same linked worktree`, then `publish both with: planning-commit-helper.sh "plan: add <task_id> ..."`. Without a brief file, print that a brief at `todo/tasks/<task_id>-brief.md` is still required for publication (see `reference/planning-publication-lifecycle.md`).
- `EDIT: .agents/scripts/planning-publication-reconcile.sh:242-249` — distinct return codes: keep 3 for task absent; 1 for `ref:GH#` mismatch; new 4 for missing/symlinked brief.
- `EDIT: .agents/scripts/planning-publication-reconcile.sh:281-287` — warning names the failed check: `TODO line lacks ref:GH#N`, or `brief todo/tasks/<task_id>-brief.md missing on default branch`. Keep `retaining publication:pending` wording.

### Complete Write Surface

- **Callers/readers:** `_publication_validate_mapping` is called only from `_publication_reconcile_one` (`rg -n "_publication_validate_mapping" .agents/scripts/`); confirm before changing return codes. `PUBLICATION_RECONCILE_SUMMARY` counts must stay unchanged (failed=1 for both new codes).
- **Writers/mutation paths:** messages only; no label or file writes change.
- **Existing verification/tests:** `.agents/scripts/tests/test-claim-task-id-no-orphan.sh` (Test 17 literal); `rg -l "planning-publication-reconcile" .agents/scripts/tests/` for reconcile tests that may assert the old warning text.
- **Schemas/config:** N/A — no config.
- **Generated/deployed mirrors:** deployed by `setup.sh` to `~/.aidevops/agents/scripts/`; no generated output.
- **Migrations/backfills:** N/A — messages only.
- **Cleanup/rollback paths:** revert PR.

### Implementation Steps

1. Read both functions; confirm callers of `_publication_validate_mapping`.
2. Add the brief/publish lines to the canonical advisory (stderr only, after the existing `printf`).
3. Split reconcile return codes and warnings; keep summary counters identical.
4. Run existing tests and shellcheck.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A — no new state.
- **Migration/rollback:** N/A.
- **Mixed-version/backward compatibility:** stdout of `claim-task-id.sh` (`task_id=`, `ref=` lines) is machine-parsed — new text must go to stderr only.
- **Idempotency/retry:** unchanged.
- **Partial failure/recovery:** unchanged; issue stays `publication:pending` as today.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-claim-task-id-no-orphan.sh
shellcheck .agents/scripts/claim-task-id-issue.sh .agents/scripts/planning-publication-reconcile.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** no-orphan test proves stdout stays clean and the advisory remains stderr; shellcheck/linters cover both scripts.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** do not change publication semantics (what is required to publish) or label projection; messaging and return-code granularity only.

**AI brief owner:** marcusquinn interactive session.

### Files Scope

- `.agents/scripts/claim-task-id-issue.sh`
- `.agents/scripts/planning-publication-reconcile.sh`

## Acceptance Criteria

- [ ] From a canonical checkout, `claim-task-id.sh --brief-file <file> ...` prints to stderr both the TODO line and the `todo/tasks/<task_id>-brief.md` destination plus the `planning-commit-helper.sh` publish command; stdout still contains only the machine-readable `key=value` lines.
- [ ] A merged TODO line with correct `ref:GH#N` but no brief makes the reconciler warn `brief todo/tasks/<task_id>-brief.md missing on default branch`; a ref mismatch warns about the ref; neither removes `publication:pending`.
- [ ] `test-claim-task-id-no-orphan.sh` passes unchanged and shellcheck is clean.

<!-- aidevops:brief-schema=v2 -->

# fix(full-loop): define the cleanup-receipt failure helper at file scope

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `full-loop cleanup receipt lock deferred handoff regression` → 0 hits
- [x] Discovery pass: no open issue or PR names `_full_loop_cleanup_fail`; regression introduced by PR #34471 (GH#34468), merged 2026-10-12T01:11Z
- [x] File refs verified at origin/main 581321e584: `_full_loop_receipt_lock_release` `.agents/scripts/full-loop-cleanup-receipt.sh:497-516`; first caller `full_loop_write_cleanup_deferred` `:552`
- [x] Tier: `tier:simple` — one block moved within one file; no behaviour change beyond restoring the intended definitions
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the filing session

## Origin

- **Created:** 2026-10-12
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** `full-loop-helper.sh merge` of a framework PR printed `full-loop-cleanup-receipt.sh: line 571: _full_loop_cleanup_fail: command not found` and `Post-merge worktree cleanup deferred, but durable handoff evidence could not be recorded (reason: receipt-write-failed)`.

## What

`_full_loop_cleanup_fail` and the GH#34468 globals (`_FULL_LOOP_CLEANUP_FAILURE_REASON`, `_FULL_LOOP_RECEIPT_LOCK_FAILURE`, `_FULL_LOOP_REASON_WRITE_FAILED`) exist as soon as `full-loop-cleanup-receipt.sh` is sourced, and `_full_loop_receipt_lock_release` only releases the lock.

## Why

- PR #34471 placed the new globals and the `_full_loop_cleanup_fail` definition inside the body of `_full_loop_receipt_lock_release`, after its `[[ -n "$_FULL_LOOP_RECEIPT_LOCK" ]] || return 0` guard. They are defined only after the first release of a held lock in the current shell.
- A fresh merge process whose first receipt write fails before any release (invalid arguments, jq missing, path unavailable, lock acquisition failure) hits `command not found`, records no reason, and the caller reports the default `receipt-write-failed`. The GH#34468 one-retry on `receipt-lock-timeout` in `_merge_record_deferred_cleanup_owner` (`.agents/scripts/full-loop-helper-merge-cleanup.sh`) therefore never triggers on that path.
- Every release also resets `_FULL_LOOP_CLEANUP_FAILURE_REASON` and `_FULL_LOOP_RECEIPT_LOCK_FAILURE` to empty.
- Read-only repro on the deployed file (Bash 3.2 and 5): after `source`, `declare -F _full_loop_cleanup_fail` fails and `_FULL_LOOP_REASON_WRITE_FAILED` is unset; `full_loop_write_cleanup_deferred owner/repo 1 "" "" x session` prints `command not found` with an empty reason; after one `_full_loop_receipt_lock_release` with a lock path set, the same call records `invalid-receipt-arguments`.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** exact edit known; one file; restores the layout the GH#34468 diff intended.

## How

### Files to Modify

- `EDIT: .agents/scripts/full-loop-cleanup-receipt.sh` — in `_full_loop_receipt_lock_release` restore the indented `_FULL_LOOP_RECEIPT_LOCK=""` and `return 0` and close the function; move the GH#34468 comment, the three globals and `_full_loop_cleanup_fail` to file scope directly after it.

### Complete Write Surface

- **Callers/readers:** `full_loop_write_cleanup_deferred` (same file); `_merge_record_deferred_cleanup_owner` and `_merge_finalize_post_merge` read `_FULL_LOOP_CLEANUP_FAILURE_REASON` (`.agents/scripts/full-loop-helper-merge-cleanup.sh`, `.agents/scripts/full-loop-helper-merge.sh`).
- **Writers/mutation paths:** unchanged; the receipt lock and receipt file logic are not touched.
- **Existing verification/tests:** `.agents/scripts/tests/test-full-loop-cleanup-receipt.sh`.
- **Schemas/config:** N/A because no setting changes.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/`; no generated copy.
- **Migrations/backfills:** N/A because state formats are unchanged.
- **Cleanup/rollback paths:** `git revert`.

### Implementation Steps

1. Replace the body tail of `_full_loop_receipt_lock_release` so it ends with a tab-indented `_FULL_LOOP_RECEIPT_LOCK=""`, `return 0`, `}`.
2. Place the comment, `_FULL_LOOP_CLEANUP_FAILURE_REASON=""`, `_FULL_LOOP_RECEIPT_LOCK_FAILURE=""`, `_FULL_LOOP_REASON_WRITE_FAILED="receipt-write-failed"` and the unchanged `_full_loop_cleanup_fail` function at file scope after it.

### Hazards and Compatibility

- **Concurrency/atomicity:** none; definitions only.
- **Migration/rollback:** none.
- **Mixed-version/backward compatibility:** callers already use `${_FULL_LOOP_CLEANUP_FAILURE_REASON:-...}` defaults.
- **Idempotency/retry:** the lock-timeout retry now works as designed.
- **Partial failure/recovery:** unchanged.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/full-loop-cleanup-receipt.sh
AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-full-loop-cleanup-receipt.sh
```

- **Surface mapping:** the suite covers receipt write, lease and lock behaviour. Production proof: in a fresh shell that sources the file, `declare -F _full_loop_cleanup_fail` succeeds and an invalid-argument `full_loop_write_cleanup_deferred` call records `invalid-receipt-arguments`.
- **Broad verification trigger:** Not required — no shared contract, root tooling or release infrastructure change.

### Scope Boundaries

**Hard boundaries:** do not change lock timing, retry counts, receipt schema or merge-wrapper messages.

**Not in scope (follow-up):** why the receipt lock was not acquired within 10s during the observed merge (2,705 receipts in the receipt directory) is separate.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/full-loop-cleanup-receipt.sh`

## Acceptance Criteria

- [ ] Sourcing the file defines `_full_loop_cleanup_fail` and the three globals before any lock release.

  ```yaml
  verify:
    method: manual
    prompt: "In a fresh bash 3.2 shell, source the file, run `declare -F _full_loop_cleanup_fail`, then call `full_loop_write_cleanup_deferred owner/repo 1 '' '' x session` and confirm `_FULL_LOOP_CLEANUP_FAILURE_REASON` is `invalid-receipt-arguments` with no `command not found`"
  ```

- [ ] Existing receipt suite passes on Bash 3.2.

  ```yaml
  verify:
    method: bash
    run: "AIDEVOPS_BASH_REEXECED=1 /bin/bash .agents/scripts/tests/test-full-loop-cleanup-receipt.sh"
  ```

- [ ] ShellCheck reports no findings.

  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/full-loop-cleanup-receipt.sh"
  ```

<!-- aidevops:brief-schema=v2 -->

# perf(full-loop): drain the cleanup-receipt archive backlog in one run so worktree admission scans a small hot set

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent GH#38332)
- **Conversation context:** Dispatch-stage evidence shows worker launches failing on cleanup-receipt lock timeouts. The hot receipt set is ~4x larger than it needs to be.

## What

`_full_loop_archive_cleanup_receipts` (`.agents/scripts/full-loop-cleanup-receipt.sh`) should archive every eligible receipt in a run, up to a configurable cap of 1024 by default. The move should cost one `mv` per destination month, not one `mv` per file, so the global receipt mutation lock is still held only briefly.

## Why

Every worker worktree admission runs `full_loop_supersede_cleaned_receipts_for_recreated_worktree`. Under the global receipt lock, it parses the **whole** hot set in `~/.aidevops/state/full-loop-cleanup/*.json`. That is a deliberate fail-closed whole-set validation (GH#38149). GH#38240 added archiving to keep the set small, but at most 128 receipts per run, at most hourly, and only from worktree cleanup.

Measured on the maintainer host on 2026-11-15:

- Hot set: 4,588 receipts (21 MB). 3,477 are CLEANED with every timestamp older than 7 days, so they are eligible to archive today (dry run of the exact jq selection, read-only).
- Archive ctimes show runs at 17, 19 and 21 on Nov 14, then 00, 02 and 06 on Nov 15: 716 receipts in total, 128 per run. At that rate the backlog lasts about four days, and receipts keep arriving at about 116 per day.
- `dispatch-stages.tsv`, 05:00–09:59Z: `precreate.verify.reconcile_scan` averaged 37.5 s (max 170.4 s) and `precreate.verify.reconcile_lock` 13.6 s (max 45.8 s). In cycle `20261115T074145Z-21778`, 5 of 22 launch attempts failed with `worktree_precreation_failed` (`receipt-lock-timeout`, holder `worktree-helper.sh` held 40–46 s). Another 4 failed `claim_lock_failed`, and 6 ran out of prelaunch budget or reserve.

Scan time scales with the hot set. After draining, about 1,100 receipts remain (recent CLEANED plus non-terminal ones), so each admission's locked scan does about a quarter of today's work.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One function in a safety-critical lifecycle file. The selection predicate and fail-closed checks stay byte-identical. Only the batch size and the move mechanics change.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/full-loop-cleanup-receipt.sh` — in `_full_loop_archive_cleanup_receipts`:
  - Replace the literal 128 with `AIDEVOPS_CLEANUP_RECEIPT_ARCHIVE_BATCH`: default 1024; accept only 1–4096, otherwise fall back to the default.
  - Sort candidates by month in jq (`sort_by(.[1])`) before slicing.
  - For each month, run the existing per-file safety checks with bash builtins (`-L` on the source, the archive root and the destination; destination-name collision). Collect the passing paths, then issue one `mv -- <files...> <destination>/` for the month.
  - Any failed check or failed `mv` releases the lock and returns 1, as today. Files that did not move stay in the hot set, which is safe.
- `EDIT: TODO.md` — task entry.

### Hazards and compatibility

- Bash 3.2: indexed arrays only, no associative arrays. Flush the batch whenever the month changes in the sorted stream.
- Do not change the eligibility predicate, the hourly throttle, the whole-set validation or the lock protocol.

### Verification

```bash
shellcheck .agents/scripts/full-loop-cleanup-receipt.sh
bash .agents/scripts/tests/test-full-loop-cleanup-receipt.sh
bash .agents/scripts/tests/test-worktree-fresh-base.sh
# Fixture probe (temp AIDEVOPS_FULL_LOOP_CLEANUP_DIR): 300 old CLEANED receipts across 2 months + recent CLEANED
# + old DEFERRED + a pre-existing archive name collision → old CLEANED moved with one mv per month (up to the cap),
# recent/DEFERRED untouched, collision returns 1 without overwriting.
```

### Files Scope

- `.agents/scripts/full-loop-cleanup-receipt.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] One housekeeping run archives up to 1024 eligible receipts (configurable) with one `mv` per destination month.
- [ ] Recent CLEANED, non-CLEANED, malformed and symlinked receipts are never moved. A destination collision still fails closed without overwriting.
- [ ] Existing cleanup-receipt and fresh-base suites pass.

# t2165: fix issue-sync enrich 10-minute timeout

**Session origin:** interactive (chore/t2162 follow-up, user-directed)

## What

The `sync-on-push` job in `.github/workflows/issue-sync.yml` times out at 10 minutes during the `Enrich plan-linked issues` step. When it times out, the downstream `Commit and push TODO.md updates` step is cancelled, breaking the end-to-end TODO.md → GitHub issues round-trip. Evidence: run `24544622121` (2026-04-17T02:28:58Z) on chore/t2162 merge hit the cap and was cancelled.

## Why

Per-task enrichment in `_enrich_process_task` (`.agents/scripts/issue-sync-helper.sh:924`) makes 4–5 `gh` API calls per open task:

1. `_enrich_apply_labels` (line 824): `gh issue edit --add-label` + `_reconcile_labels` (view+edit) + `_apply_tier_label_replace` (view+edit) — that's 3 reads and up to 3 writes, even when nothing needs changing.
2. `_enrich_update_issue` (line 869): `gh issue view --json body` + `gh issue edit --title` (always runs even when body is unchanged/preserved).
3. `sync_relationships_for_task` (usually no-op).

At ~1.5s per API call × ~5 calls × 145 open `ref:GH#` tasks in `TODO.md` → ~18 minutes of work squeezed into a 10-minute cap. The job can never complete on a repo this size. Meanwhile, most tasks have already been enriched on prior runs and their labels/title/body all already match — the API calls produce no change but still cost the wall time.

## How

Two independent changes that compose:

### Change 1: pre-fetch state once per task (surgical, low-risk)

In `_enrich_process_task`, immediately after resolving `num`, fetch `title,body,labels` in a single `gh issue view --json title,body,labels` call and parse once:

- `current_title`, `current_body`, `current_labels_csv`

Extend `_enrich_apply_labels`, `_enrich_update_issue`, `_apply_tier_label_replace`, and `_reconcile_labels` to accept pre-fetched `current_labels` (and `current_title`/`current_body` on the update helper) as trailing optional args. Each helper:

- Uses the pre-fetched value when provided (no API read).
- Falls back to the existing `gh issue view` fetch when the arg is empty — preserves current behaviour for any caller not on the fast path (e.g. direct test invocation of the helpers in isolation).

Then add three small skip-when-unchanged gates:

- `_enrich_apply_labels`: if every desired label in `labels` is already present in `current_labels`, skip the `gh issue edit --add-label` call.
- `_enrich_update_issue`: if `current_title == title`, skip the title-only `gh issue edit --title` call (today the code falls into the title-only branch any time body is unchanged — the title call still runs even when the title matches). Body comparison already exists (line 887/895).
- `_apply_tier_label_replace`: the existing ratchet logic already skips when tier is unchanged; receiving `current_labels` eliminates the `gh issue view` read that feeds it.

Expected cost per task:

- Best case (all values match, most tasks in a steady-state repo): 1 API call (the bulk view). 145 × 1.5s ≈ **3.6 min**.
- Mixed case (a handful of tasks need label/title updates): 2–3 API calls per drifted task. Amortised across the batch: well under the 10-min cap.
- Worst case (every task is drifted): same cost as today — no regression.

### Change 2: bump `sync-on-push` timeout 10→20 (safety net)

Even after the optimisation lands, a cold-cache run or a large backlog day can still run long. Raise `timeout-minutes` from 10 to 20 on the `sync-on-push` job as an independent safety net. No change to the other jobs' timeouts — they operate on single issues / single PRs and stay well under their existing caps.

## Acceptance criteria

1. `_enrich_process_task` issues exactly **one** `gh issue view` call per task on the happy path (verified by local `--dry-run` instrumentation or `set -x` spot-check).
2. When `current_title == title`, `current_body == body` (per existing t2063 check), and all desired labels are already present, `_enrich_process_task` issues **zero** `gh issue edit` calls.
3. All existing behavioural branches are preserved:
   - `FORCE_ENRICH=true` still refreshes the body.
   - Brief-file-authoritative path (t2063) still refreshes the body when diff ≠ 0.
   - Sentinel-only path (GH#18411) still refreshes when diff ≠ 0.
   - External-content preservation path (no brief, no sentinel) still preserves.
   - Ratchet rule (t2111) on tier labels still preserves escalated tiers.
   - Label reconciliation (GH#17402) still removes stale tag-derived labels when `add_ok=true`.
4. `sync-on-push` `timeout-minutes: 20` lands in the workflow.
5. On the merge of this PR itself, the `Enrich plan-linked issues` step completes within the new 20-minute cap (self-verifying end-to-end test).

## Risk and rollback

- **Risk to pulse/workers:** zero. Pulse calls `issue-sync-helper.sh pull/close/reopen` only (see `pulse-wrapper.sh:1553-55`). The enrich command and its helpers are only invoked from the GitHub Actions workflow. Pulse's local dispatch/dedup/merge logic is untouched.
- **Risk to sync behaviour:** low. Defensive fallback in every helper — if `current_*` args are empty (test invocation, future callers), behaviour is identical to today. The skip-when-unchanged gates only fire on exact equality, so label drift, title drift, or body drift all still trigger the existing write paths.
- **Rollback:** revert the single PR. No schema change, no label change, no data migration.

## Files to modify

- EDIT: `.agents/scripts/issue-sync-helper.sh`
  - `_enrich_process_task` (line 924): bulk pre-fetch `title,body,labels` after `num` resolved, pass to helpers
  - `_enrich_apply_labels` (line 824): accept `current_labels_csv`, skip add when no diff
  - `_enrich_update_issue` (line 869): accept `current_title`/`current_body`, skip title-only call when `current_title == title`
  - `_apply_tier_label_replace` (line 172): accept `current_labels_csv`
  - `_reconcile_labels` (line 275): accept `current_labels_csv`
- EDIT: `.github/workflows/issue-sync.yml` line 35: `timeout-minutes: 10` → `20`

## Verification

Local dry-run:

```bash
cd /Users/marcusquinn/Git/aidevops-fix-t2165-issue-sync-timeout
# Smoke test — should print [DRY-RUN] Would enrich ... and exit cleanly
bash .agents/scripts/issue-sync-helper.sh enrich t2165 --dry-run
# Timing: capture API-call count via strace or set -x before/after
time bash .agents/scripts/issue-sync-helper.sh enrich --dry-run 2>&1 | tee /tmp/enrich-after.log
```

After merge, the next TODO.md push triggers `sync-on-push` — watch that run complete within 20 min and the `Commit and push TODO.md updates` step actually fire.

## Context

- t2162 merge (PR #19479, commit 09e4928a3) was the trigger: its `sync-on-push` run timed out exactly as described, surfacing the problem.
- t2048 (PR #18677) added `SYNC_PAT` fallback to `sync-on-pr-merge` but doesn't help here — that path requires t2166's operational setup regardless.
- Enrich decomposition (PR #18715, t1858) split `cmd_enrich` into the current focused helpers — that refactor is the reason this surgical optimisation is feasible without rewriting the whole command.

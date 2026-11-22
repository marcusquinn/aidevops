## What

Make the partial-continuation merged-PR lane (`_pmpc_reconcile_recent_merges`) able to keep up at high merge volume, so merged `For/Ref #N` worker partials return their issue to `status:available` + `auto-dispatch` within one Pulse cycle even when another account or a person merged the PR.

## Why (evidence, 2026-11-20, one private high-volume managed repo)

- 127 open `status:in-review` issues; 113 had no open PR; 112 lacked `auto-dispatch`; the newest marker on 34 of the 40 oldest was `PARTIAL_PARENT_CLOSEOUT`. These are finished worker partials that dispatch never sees again, which is the work the user ends up doing in interactive sessions.
- A dry run of the merge-time guard on one of them (PR body `Ref #N`, `origin:worker`, merged by another account) returns `returned #N to status:available`. The guard is correct, but it only runs when this Pulse performs the merge. Recovery of other merges depends on the reconcile lane.
- The lane walks every merged PR in a 7-day window, newest first: about 4,100 merged PRs, about 41 pages, so one page takes about 360s (a production run gave 68/78 decisions `no partial continuation — it closes #N`, each costing 2 GitHub reads). The Pulse gives the partial pass about 15s per repo in the 60s `stale_blocked_reconcile` stage, half of that for this lane. So it moves deeper into history while new merges on page 1 are never reached, and the in-review backstop gets about one issue per pass. The repo's completion stamp was 18 days old.

## How

1. In `_pmpc_reconcile_recent_merges` (`.agents/scripts/pulse-merge-partial-continuation.sh`), drop rows that the guard would reject from data already in the list page, with no API call: a body matching `_PMPC_CLOSING_REF_PATTERN` (case-insensitive, a superset of `_extract_linked_issue`'s closing forms) or an `origin:*` label other than `origin:worker`/`origin:worker-takeover`. Same outcome as `_pm_restore_partial_continuation` (labels/closing checks at its start) for the same body/labels.
2. Make the walk incremental: persist the start epoch of each walk, and on completion set the next walk's floor to that start minus an overlap (`PULSE_PARTIAL_MERGED_OVERLAP_SECONDS`, default 3600), never older than the lookback. The in-review revisit phase stays the backstop for unreadable reads and older merges.
3. Keep the cursor format compatible (line 1 page, then pending PR numbers).

## Files Scope

- `.agents/scripts/pulse-merge-partial-continuation.sh`
- `.agents/scripts/tests/test-pulse-merge-partial-continuation.sh`

## Acceptance

- Closing or foreign-origin merged PRs on a list page make zero per-PR reads; candidates still go through the unchanged guard.
- After one complete walk, the next walk stops at the high-water floor (page 1 only in steady state).
- `test-pulse-merge-partial-continuation.sh` passes; ShellCheck clean.
- Production: after deploy, high-volume repos' partial-continuation pass stamps complete within the normal cadence, and the stranded in-review count stays near zero.

## Verification

`bash .agents/scripts/tests/test-pulse-merge-partial-continuation.sh`; `shellcheck .agents/scripts/pulse-merge-partial-continuation.sh`; then post-deploy, count open in-review issues without an open PR, and check pulse.log `partial-continuation pass due for <repo>: complete_stamp_age_s`.

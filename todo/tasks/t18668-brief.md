<!-- aidevops:brief-schema=v2 -->

# t18668: restore footprint defer suppression for bodiless candidate snapshots and size its TTL to the reconsideration gap

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `footprint defer suppression candidate body TTL pulse dispatch` → 0 hits — no relevant lessons
- [x] Discovery pass: `prework-discovery-helper.sh` found no open related PR or issue. Related history: GH#30619 (6e0f2e0ed0, introduced the durable defer and its suppression), GH#32977 (same-batch footprint reservations), GH#33293 (claimed no-auto-dispatch coordinator exclusion), GH#33998 (shorter reservation critical section)
- [x] File refs verified at origin/main 3ffa1d564a: `_footprint_defer_should_suppress` (`.agents/scripts/dispatch-dedup-footprint.sh:264`), `_FOOTPRINT_DEFER_TTL_SECONDS` (`:50`); caller `_dispatch_skip_for_footprint_defer` (`.agents/scripts/pulse-dispatch-lib-candidates.sh:286`) from `_dispatch_process_candidate` (`.agents/scripts/pulse-dispatch-lib.sh:548`); candidate snapshot fields (`.agents/scripts/pulse-repo-meta.sh:327`)
- [x] Tier: `tier:standard` — one dispatch-dedup module plus its diagnostics rule; no dispatch, claim or trust gate weakened
- [x] Seeded draft PR decision recorded: skipped — implemented interactively in the same session

## Origin

- **Created:** 2026-10-11
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** Enrichment throughput drive, following t18665 (attempt-recency ordering) and t18667 (post-label refill budget). Footprint-deferred candidates were re-running the full dispatch ceremony every time a wave reached them.

## What

`_footprint_defer_should_suppress` works with the candidate JSON that Pulse actually passes it:

- When the candidate JSON has no `body`, it reads the candidate issue body instead of treating the missing body as a changed footprint. An unreadable candidate falls through to the live check without ending the defer.
- Local expiry is checked before any GitHub read.
- A blocker that became a `parent-task` or claimed `no-auto-dispatch` coordinator wakes the defer (`blocker_coordinator_recheck`), so the live check applies its coordinator exclusions.
- Each suppression logs `[footprint-defer] event=suppressed ...`, and `pulse-diagnose-helper.sh` gains a `pfd-suppressed` rule.
- The default TTL rises from 1800 s to 21600 s. `AIDEVOPS_FOOTPRINT_DEFER_TTL_SECONDS` still overrides it.

## Why

- Candidate snapshots are listed with `number,title,url,assignees,labels,createdAt,updatedAt` (`pulse-repo-meta.sh:327`), with no body. That was already true when GH#30619 shipped. `.body // ""` gives an empty footprint, so every reconsideration woke with `candidate_footprint_changed`.
- `pulse-stats.json` (8-day retention): `dispatch_candidate_blocked_footprint_overlap` 681, `dispatch_candidate_footprint_defer_suppressed` 0.
- `pulse.log` (66.1 h): 342 deferrals and 305 wakes (297 `candidate_footprint_changed`, 8 `lifecycle_invalidation`). 246 of the spurious wakes were re-deferred against the same blocker after the full candidate ceremony (repo refresh, metadata fetch, dedup layers, large-file gate). Wake to re-defer took p50 78 s and p90 147 s, 21,735 candidate-seconds in total. 267 of the 342 deferrals were in a managed private repo.
- TTL: at those reconsiderations the defer was p25 7,449 s, median 10,593 s and p75 15,087 s old. A 1800 s TTL covered 5% (11/237), 21600 s covers 89% and 43200 s covers 100%.

## How

### Files to Modify

- `EDIT: .agents/scripts/dispatch-dedup-footprint.sh`
  - new `_footprint_defer_candidate_body`: use a string `body` from the candidate JSON, otherwise `gh_issue_view <N> --json body` (raw `gh` when the wrapper is not loaded); non-zero when unreadable.
  - new `_footprint_defer_blocker_wake_reason`: `blocker_lifecycle_changed` (not open or no active status label), `blocker_coordinator_recheck` (`parent-task`, or `no-auto-dispatch` + `status:claimed`), `blocker_footprint_changed`; empty while the blocker still holds the recorded footprint.
  - `_footprint_defer_should_suppress`: force-dispatch → expiry → candidate body/hash → blocker; log `event=suppressed`.
  - `_FOOTPRINT_DEFER_TTL_SECONDS` default 21600.
- `EDIT: .agents/scripts/pulse-diagnose-helper.sh` — `pfd-suppressed` rule; refresh the `pfd-deferred`/`pfd-wake` line references.
- `EDIT: .agents/scripts/tests/test-dispatch-footprint-overlap.sh` — the `gh` mock serves candidate bodies, an extra blocker label and a call log; Tests 20–24 use a production-shaped candidate snapshot.

### Complexity Impact

- `_footprint_defer_should_suppress`: 63 → 61 body lines (blocker evaluation moved to a helper).
- New `_footprint_defer_candidate_body`: 15 body lines. New `_footprint_defer_blocker_wake_reason`: 23 body lines.
- `complexity-regression-helper.sh check` reports 0 new violations for function-complexity, nesting-depth and bash32-compat.

### Complete Write Surface

- **Callers/readers:** `_dispatch_skip_for_footprint_defer` only. `_footprint_defer_status_json` and `pulse-diagnose-issue.sh` display records whose schema is unchanged. No consumer branches on specific `wake_reason` values.
- **Writers/mutation paths:** defer state files under `~/.aidevops/cache/footprint-defers/` (schema v1; `suppressed_count`/`last_checked_at` as before) and new `event=suppressed` lines in `pulse.log`. No labels, claims, comments or other GitHub writes.
- **GitHub reads:** each non-expired suppression check reads the candidate body (one REST-capable `gh_issue_view`) and the blocker, which was already read. Before, each reconsideration ran the full candidate ceremony instead (metadata fetch, dedup layers, in-flight label lists, repo refresh).
- **Schemas/config:** only the `AIDEVOPS_FOOTPRINT_DEFER_TTL_SECONDS` default changes. Existing records keep their recorded `expires_at` and pick up the new TTL when re-deferred.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*.sh` into the runtime bundle.
- **Migrations/backfills:** none.
- **Cleanup/rollback paths:** revert the PR. `AIDEVOPS_FOOTPRINT_DEFER_TTL_SECONDS=1800` restores the old window.

### Hazards and Compatibility

- **Safety:** suppression skips a candidate only when its footprint is unchanged and its recorded blocker is still open, has an active status label, is not a coordinator, and has the footprint it had when the live check found the overlap. The live check would defer that candidate again.
- **Fail-closed blocker read (unchanged):** an unreadable blocker keeps suppressing as GH#30619 designed. The TTL and event-driven `lifecycle_invalidation` (issue close, PR merge, claim release) bound this.
- **Known divergence:** the live in-flight read lists at most 50 open issues per status label. A recorded blocker outside that window keeps suppressing until the TTL ends. This is conservative: it never admits an overlap.
- **Longer TTL:** every suppression re-reads the candidate and blocker, and close/merge/release events wake defers immediately. The TTL only bounds drift that those reads cannot see (low-information basename config, extraction changes, blocker-read outages).
- **Bash 3.2:** no new constructs; the suite passes on `/bin/bash` 3.2.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/dispatch-dedup-footprint.sh .agents/scripts/pulse-diagnose-helper.sh .agents/scripts/tests/test-dispatch-footprint-overlap.sh
bash .agents/scripts/tests/test-dispatch-footprint-overlap.sh
/bin/bash .agents/scripts/tests/test-dispatch-footprint-overlap.sh
bash .agents/scripts/tests/test-pulse-diagnose-helper.sh
.agents/scripts/complexity-regression-helper.sh check --base origin/main --working-tree --metric function-complexity
```

- **Regression proof:** run against the origin/main module, 4 of the 5 new production-shaped cases fail. The Test 20 failure is the live symptom: `wake_reason=candidate_footprint_changed` at age 0.
- **Runtime:** after deploy, `pulse.log` should show `[footprint-defer] event=suppressed` and `pulse-stats.json` a non-zero `dispatch_candidate_footprint_defer_suppressed`. `candidate_footprint_changed` wakes followed by a same-blocker re-defer within 900 s should fall toward zero (`defer_age.py`-style pairing).
- **Broad verification trigger:** Not required — no shared config, root tooling or release infrastructure change.

### Files Scope

- `.agents/scripts/dispatch-dedup-footprint.sh`
- `.agents/scripts/pulse-diagnose-helper.sh`
- `.agents/scripts/tests/test-dispatch-footprint-overlap.sh`
- `TODO.md`
- `todo/tasks/t18668-brief.md`

## Acceptance Criteria

- [ ] A candidate snapshot without `body` and with an unchanged footprint is suppressed while its recorded blocker is open, in flight, not a coordinator and unchanged.
- [ ] An unreadable candidate falls through to the live check without tombstoning the defer.
- [ ] An expired defer wakes before any GitHub read.
- [ ] A `parent-task` or claimed `no-auto-dispatch` blocker wakes the defer with `blocker_coordinator_recheck`.
- [ ] The default TTL is 21600 s, and `AIDEVOPS_FOOTPRINT_DEFER_TTL_SECONDS` still overrides it.
- [ ] ShellCheck, the footprint suite on Bash 5 and 3.2, the diagnose suite and the complexity gates pass.

## Context & Decisions

- **Read the body; don't widen the snapshot:** adding `body` to the candidate listing would enlarge every cycle's listing for every open issue, only to serve the few candidates with an active defer.
- **Read rather than infer from `updatedAt`:** label and comment activity also bumps `updatedAt`, so it would only sometimes save the read and adds a stale-snapshot edge case.
- **21600 s, not 43200 s:** covers 89% of the observed reconsiderations and keeps a 6 h backstop for drift the per-check reads cannot see.
- **Not in scope:** the 50-per-label in-flight read window, pruning tombstoned defer records, and in-review zombie blockers in the managed private repo (a separate authorized cleanup).

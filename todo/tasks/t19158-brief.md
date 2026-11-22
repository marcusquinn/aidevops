# t19158: perf(gh-transport): replay counted-list page frames (total_count) so unchanged check-run and status reads cost no REST quota

## Origin

Interactive productivity mission session, follow-up to GH#39233 / PR #39238. Evidence comes from the local REST ledger `~/.aidevops/logs/gh-api-calls.log` on 2026-11-19.

## What

PR #39238 lets the conditional cache replay explicit-pagination page frames in two cases: the frame links onward, or it is a final raw JSON array with room left. Counted-list endpoints return an object such as `{"total_count": N, "check_runs": [...]}` or `{"total_count": N, "statuses": [...], "state": ...}`. Their final pages never qualify, so every read stays a full-cost 200.

Add a third exact-replay rule. An unfiltered page whose JSON body is an object with an integer (non-boolean) `total_count` may be stored and replayed, whatever its length.

## Why

- Between 12:20Z and 13:40Z on 2026-11-19, the ledger recorded 5,723 quota-costing REST attempts, against GitHub's 5,000/hour primary limit. The 13:19Z and 13:36Z Pulse cycles then ended `blocked` on `rest-core-quota` with 0 dispatches (`~/.aidevops/logs/pulse-cycle-index.jsonl`).
- In that window `pulse-merge-routine.sh` sent 692 explicit-pagination reads for `repos/:o/:r/commits/:id`, all page 1 and all full cost. The source is `.agents/scripts/pulse-merge-required-checks.sh:728` (`commits/<sha>/check-runs?per_page=100 --paginate --slurp`). Check runs for a settled PR head are stable between merge-routine passes.
- Why this is exact: any added or removed item changes `total_count`, which changes every page body and therefore its ETag. A page that would need to reveal a new next page cannot be answered by a 304. Each requested page is still validated on its own.
- Live check: `commits/<sha>/check-runs?per_page=2` returned `total_count: 202` with `rel="next"`, and `commits/<sha>/status` returns `total_count` plus `statuses`.

## How (Approach)

- `.agents/scripts/gh_conditional_request.py`: extend `_final_page_has_room` (or add a sibling helper called from `page_frame_replayable`) to accept a parsed JSON object with an integer `total_count` that is not `bool`. Keep the existing guards: `_FINAL_PAGE_FILTERS` (`--jq`/`--template`/`--field` final pages stay ineligible, because the stored stdout would not contain `total_count`), the notifications exclusion, and the `per_page` validity checks. Update the module docstring to state the counted-list rule.
- `.agents/scripts/tests/test-gh-conditional-cache.py`: add cases modelled on the existing page-frame tests (`rg -n "page_frame|full final" .agents/scripts/tests/test-gh-conditional-cache.py`):
  - a full final counted-list page (`{"total_count": 2, "check_runs": [a, b]}` with `per_page=2`) is replayed on 304;
  - an object without `total_count`, and one with `"total_count": true`, are not replayed when full and final;
  - a `--jq` final counted-list page is not replayed.

### Files Scope

- `.agents/scripts/gh_conditional_request.py`
- `.agents/scripts/tests/test-gh-conditional-cache.py`

## Acceptance Criteria

- `python3 .agents/scripts/tests/test-gh-conditional-cache.py` passes, including the new cases.
- `bash .agents/scripts/tests/test-gh-shim.sh` and `bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh` pass.
- Live: two identical `gh api 'repos/<o>/<r>/commits/<sha>/check-runs?per_page=100' --paginate --slurp` reads through the worktree shim (`.agents/scripts/gh`) give 200 then 304, with identical output.
- After deploy, ledger rows for `caller=pulse-merge-routine.sh`, `route=explicit-rest-pagination`, `endpoint=repos/:o/:r/commits/:id` show a non-zero 304 count.

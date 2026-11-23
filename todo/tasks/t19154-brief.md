# t19154: perf(gh-transport): revalidate explicit-pagination pages with ETags so unchanged comment lists cost no REST quota

## Origin

Interactive productivity mission session (Pulse/worker throughput). Evidence from the local REST ledger `~/.aidevops/logs/gh-api-calls.log` on 2026-11-19.

## What

Explicit REST pagination pages (route `explicit-rest-pagination`, issued by `.agents/scripts/gh-rest-pagination-lib.sh`) never send `If-None-Match`, so every page is a full-cost 200. Allow the conditional cache (GH#38566) to store and replay these page frames when replay is provably exact.

## Why

- In the 38 minutes from 14:15Z, the shim recorded 3,517 quota-costing REST attempts, against GitHub's 5,000/hour primary limit. 1,402 of them (40%) were `explicit-rest-pagination` with **0** 304 responses. Over the same window, ordinary governed GETs (`rest-response-owned`) returned 304 for 1,246 of 2,524 attempts (49%).
- The hottest paginated reads are issue-comment lists used by Pulse, dispatch dedup/claim, and the headless runtime (~740 attempts in that window). They change rarely between reads.
- Pulse's merge routine and dispatch defer at the REST progress floor, so wasted quota delays throughput directly.

Root cause: `_ghrp_build_base_args` adds `--include` to read the `Link` header, and `gh_conditional_request.eligible()` rejects all `--include` requests.

## How (Approach)

- `gh-rest-pagination-lib.sh`: mark page requests with `AIDEVOPS_GH_PAGINATION_INCLUDE_OWNED=1` only when the loop, not the caller, added `--include`.
- `gh_conditional_request.py`: page frames that the loop owns are eligible. A stored frame may answer a later 304 only if either:
  - it links onward (`rel="next"`), or
  - it is a final raw JSON array with fewer items than the effective `per_page`, which is the query value capped at 100, or 30 when no value is given.
  
  A 304 carries no `Link` header, and the list ETag tracks the page body. An unchanged full final page therefore cannot reveal a newly appended page, so such frames are never stored. Frames filtered with `--jq` keep the onward-link rule only. Field-encoded queries and notification endpoints use the same rule.
- `gh_conditional_cache.py`: in frame mode, store and replay the whole included stdout (headers plus body) so the page loop reads the original `Link`. Quota telemetry still comes from the real 304 headers.

### Files Scope

- `.agents/scripts/gh-rest-pagination-lib.sh`
- `.agents/scripts/gh_conditional_request.py`
- `.agents/scripts/gh_conditional_cache.py`
- `.agents/scripts/tests/test-gh-conditional-cache.py`

## Acceptance Criteria

- A second identical paginated read of an unchanged non-full single page sends `If-None-Match`, gets a 304 at cost 0, and returns the same bytes.
- An unchanged full final page is never replayed (no truncation when a later page appears).
- A caller-requested `--include` stays ineligible.
- `python3 .agents/scripts/tests/test-gh-conditional-cache.py`, `bash .agents/scripts/tests/test-gh-shim.sh` and the pagination shim tests pass. ShellCheck reports nothing on the edited shell file.
- After deploy, the ledger shows a non-zero 304 count for `explicit-rest-pagination`.

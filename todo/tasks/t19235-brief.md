## What

Stop counting HTTP `304 Not Modified` attempts as failures in the GitHub API usage report. Callers that send their own `If-None-Match` get a free `304`. Native `gh` exits non-zero on it, so the attempt row records `outcome=error`, and `gh-api-aggregate.awk` adds it to `failed_attempts`. Report these as successful not-modified reads, with their own counter, so `failed_attempts` shows only real failures.

## Why

Evidence from `~/.aidevops/logs/gh-api-calls.log` on one host, 2026-11-21, about one hour:

- `pulse-wrapper.sh` and `pulse-merge-routine.sh` had 107 attempt rows with field 14 `error`, field 15 `304` and field 17 quota cost `0`. These are intended free revalidations, not failures.
- Callers that set `If-None-Match` themselves (`rg -l "If-None-Match" .agents/scripts --glob '*.sh'`) include `pulse-events-tickle.sh`, `pulse-repo-dormancy.sh`, `pulse-batch-prefetch-helper.sh` and `shared-gh-collaborator-permission.sh`.
- `gh-api-aggregate.awk:458-464` treats every outcome other than `success` as failed. `aidevops github auth usage` and the pulse diagnostics therefore report inflated failure counts: about 25% of the `pulse-wrapper.sh` failures in that hour. That sends diagnosis toward phantom failures, which happened during the session that filed this issue.

## How

- In `.agents/scripts/gh-api-aggregate.awk`, in the attempt rule around lines 440-464, treat `http_status == "304"` as a successful attempt whatever `outcome` says. Add a `not_modified_attempts` metric through `metric_add_dimensions`, emitted beside `successful_attempts` and `failed_attempts` (lines 103 and 525 show the emit pattern). Leave `metric_add("outcome", ...)` unchanged, so raw outcome counts still show what was logged.
- Do not change the writer (`gh-api-instrument.sh` / governor). Historical rows must classify correctly too, and an aggregator-only fix covers them.
- If a consumer of the JSON relies on the exact key set, update it. To find consumers, run `rg -n "failed_attempts" .agents/scripts` and `rg -n "successful_attempts" .agents/scripts`.

## Files Scope

- `.agents/scripts/gh-api-aggregate.awk`

## Acceptance

- On a log containing `error`/`304`/cost-`0` attempt rows, those rows count in `successful_attempts` and `not_modified_attempts`, not in `failed_attempts`.
- `404`, `422`, `5xx` and transport errors still count as failed.
- Existing aggregator tests pass. To find them: `rg -l "gh-api-aggregate" .agents/scripts/tests`.

## Verification

- The tests found above, each run with `bash`.
- Runtime: `aidevops github auth usage --since 1h` (or the `usage` subcommand of `.agents/scripts/github_auth_cli.py`) before and after. `failed_attempts` for `pulse-wrapper.sh` drops by about the count of its `error`/`304` rows in the same window.

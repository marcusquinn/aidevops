## What

`full-loop-helper.sh merge` defers every attempt with `non-required check snapshot read exit 124` while local REST pacing is active, even though all required checks pass and the API is healthy. Give the non-required check snapshot the same merge read timeout every other merge read already uses (GH#38535).

## Why

Observed 2026-11-21 on PR #39569 (all 5 required checks passed, merge state CLEAN):

- Three consecutive `full-loop-helper.sh merge 39569` attempts failed in 55–100s with `Merge deferred by GitHub read admission: non-required check snapshot read exit 124; preserve the PR and retry`.
- With `LOGFILE` captured, both the first read and the retry failed at the check-runs fetch:
  `pre-merge snapshot: check-runs fetch failed for head 9b411f1f102e ... transient check-set read rc=124 ...; retrying once with 10s timeout ... check-runs fetch failed`.
- The same `_pmrc_snapshot_checks_json` call run standalone (same head, same minute) succeeded in 3s: two check-run pages (101 runs, 369 KB raw) plus the commit status.
- `~/.aidevops/logs/gh-api-calls.log` showed the merge-window `commits/:id` page taking 9,039 ms for a 304, compared with 0.5–0.9 s outside the merge. Local transport demand was about 164 attempts/min, and the core pacing interval was about 0.56 s, so paced admission used most of the budget.
- Setting `AIDEVOPS_GH_READ_TIMEOUT=60` on the same command merged the PR in 4 minutes (merge SHA `0143138431`), confirming that the budget, not a CI or API failure, blocked the merge.

Root cause: `_full_loop_enforce_nonrequired_check_gate` (`.agents/scripts/full-loop-helper-readiness.sh`) calls `_pmrc_snapshot_checks_with_retry`, which reads through `_pmrc_gh_read` → `_gh_with_timeout read`. That path never goes through `_flm_gh_read_once`, so it keeps the generic `AIDEVOPS_GH_READ_TIMEOUT` default of 15s (`shared-gh-wrappers.sh:293`). The retry is capped at `AIDEVOPS_PULSE_MERGE_SNAPSHOT_RETRY_TIMEOUT_SECONDS` (default 10s). GH#38535 documented that pacing can take up to 10s inside a read timeout and raised all `_flm_gh_read` merge reads to 60s; this snapshot path was missed. A paginated two-page read plus the status read cannot fit in 15s/10s while pacing is engaged, so every interactive and worker merge defers under load and must be re-run manually.

## How

- In `.agents/scripts/full-loop-helper-readiness.sh` `_full_loop_enforce_nonrequired_check_gate`, resolve the merge read timeout with `_flm_merge_read_timeout` (from `full-loop-helper-merge-transport.sh`; fall back to 60 if undeclared or invalid). Invoke `_pmrc_snapshot_checks_with_retry` with `AIDEVOPS_GH_READ_TIMEOUT=<merge timeout>` and `AIDEVOPS_PULSE_MERGE_SNAPSHOT_RETRY_TIMEOUT_SECONDS=30` (the helper's accepted maximum) scoped to that call only.
- Do not change `pulse-merge-required-checks.sh` defaults; the pulse merge pass has its own deadline (`_PMP_MERGE_PASS_DEADLINE_EPOCH`) and must keep its bounds.
- Keep fail-closed semantics: a snapshot that still fails defers the merge exactly as now.

## Files Scope

- `.agents/scripts/full-loop-helper-readiness.sh`

## Acceptance

- `full-loop-helper.sh merge <PR>` with passing required checks no longer defers with `non-required check snapshot read exit 124` when local pacing adds several seconds per page.
- A genuinely failing snapshot read still defers (fail closed), and terminal non-required failures still block.
- Pulse merge-pass bounds are unchanged.

## Verification

- `bash .agents/scripts/tests/test-full-loop-merge.sh`, `bash .agents/scripts/tests/test-full-loop-merge-planning.sh`, `bash .agents/scripts/tests/test-full-loop-remote-evidence.sh`, and `shellcheck .agents/scripts/full-loop-helper-readiness.sh` pass.
- Runtime: merge this fix's own PR through the worktree's `full-loop-helper.sh merge` without any `AIDEVOPS_GH_READ_TIMEOUT` override while pacing is active, then confirm in `LOGFILE` that no `check-runs fetch failed` line appears.

## What

Make the full-loop governed merge reads actually use their intended 60-second transport timeout. Today every merge read runs under the generic 15-second read timeout, so the PR head read times out under quota pacing and the merge is refused.

## Why

GH#33673 gave merge reads a 60-second budget with `local AIDEVOPS_GH_READ_TIMEOUT="${AIDEVOPS_GH_READ_TIMEOUT:-60}"` in `_flm_gh_read_once` (`.agents/scripts/full-loop-helper-merge-transport.sh`) and `_merge_author_has_write_authority` (`.agents/scripts/full-loop-helper-merge-authority.sh`). But `.agents/scripts/shared-gh-wrappers.sh` (sourced through `shared-constants.sh`) runs `: "${AIDEVOPS_GH_READ_TIMEOUT:=15}"` at load time, after `configs/pulse-rate-limit.conf` sets the same default. So the `:-60` fallback never fires in production.

Evidence:

- A probe that sources `shared-constants.sh` and `full-loop-helper-merge.sh` the way production does prints `flm_read_effective=15` and `authority_effective=15`.
- `~/.aidevops/logs/gh-api-calls.log` holds 50+ `timeout` records from `full-loop-helper-merge-transport.sh` over about 43 hours, each with `elapsed_ms` of about 15050, in bursts of about 10 per 15 minutes.
- Governed merges of PRs #38517 and #38533 were refused with `PR head read failed (exit 124)` after required checks and the review gate passed.
- `gh-transport-governor.py` `_acquire` spends up to `min(10, timeout-5)` seconds on local pacing inside the same timeout. With 15 seconds, a paced read has about 5 seconds left for the HTTP call, which is why the failures cluster under quota pressure.

The existing tests `test_post_verification_read_admission_window` (`tests/test-full-loop-merge-cases.sh`) and `test_slow_gate_admission_reads` (`tests/test-full-loop-merge-authority-guard.sh`) `unset AIDEVOPS_GH_READ_TIMEOUT` before asserting 60. That state never happens in production, so they pass while production fails.

## How

1. Add a merge-specific knob, `AIDEVOPS_MERGE_GH_READ_TIMEOUT` (default 60), and use it in `_flm_gh_read_once` and `_merge_author_has_write_authority` in place of the generic fallback. The generic 15-second default from `shared-gh-wrappers.sh` must no longer shadow the merge budget. Keep the deadline clamp in `_gh_timeout_budget_seconds` unchanged.
2. Validate the knob as a positive integer and fall back to 60 otherwise.
3. Update both tests so they keep the production state (`shared-constants.sh` sourced, generic default 15 present) instead of unsetting the variable, assert 60, and express the caller override through `AIDEVOPS_MERGE_GH_READ_TIMEOUT`.

## Acceptance

- The probe sourcing `shared-constants.sh` and `full-loop-helper-merge.sh` reports 60 for both `_flm_gh_read_once` and `_merge_author_has_write_authority`.
- `AIDEVOPS_MERGE_GH_READ_TIMEOUT=7` still overrides it to 7.
- `bash .agents/scripts/tests/test-full-loop-merge-cases.sh` and `bash .agents/scripts/tests/test-full-loop-merge-authority-guard.sh` pass. Without the fix, the updated tests fail.
- ShellCheck is clean on every changed file.

## Files Scope

- `.agents/scripts/full-loop-helper-merge-transport.sh`
- `.agents/scripts/full-loop-helper-merge-authority.sh`
- `.agents/scripts/tests/test-full-loop-merge-cases.sh`
- `.agents/scripts/tests/test-full-loop-merge-authority-guard.sh`

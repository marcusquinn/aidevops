<!-- aidevops:brief-schema=v2 -->

# fix(pulse): fix-the-fixer detector caches verdicts so hourly runs progress within the 60s stage bound

## Pre-flight

- [x] Memory recall: `fix-the-fixer detector timeout verdict cache` → 0 hits
- [x] Discovery pass: last changes are #38623 (auth capability reporting) and GH#36535 (direct label check); 0 open PRs or claimed issues touch the detector
- [x] File refs verified at `9160ac3864`: `pulse-fix-the-fixer-detector.sh:118` (`_hash_text`), `:476-557` (`cmd_check`), `:559-589` (`_log_run_summary`), `:594-686` (`cmd_run`); `pulse-wrapper.sh:1586-1590` (60s stage bound); `pulse-wrapper-cycle-gates.sh:432-468` (hourly sentinel)
- [x] Tier: `tier:standard`

## Origin

- **Created:** 2026-11-16
- **Created by:** ai-interactive (productivity mission, GH#38332 follow-up)
- **Conversation context:** a pulse stage-timing audit found that the detector's cold path never finishes.

## What

Each hourly detector run makes forward progress and finishes inside the Pulse stage bound:

1. A completed classification (`YES` or `NO`) is cached per `slug + issue number + sha256(title + body)`. Later runs skip a cached, unchanged issue without an LLM call. An edited title or body changes the hash and is classified again. `SKIP` and `SKIP_AUTH` outcomes are never cached, so they retry.
2. `cmd_run` enforces its own wall-clock budget below the stage timeout (default 40s). When the budget is spent it stops taking new issues, writes the run summary and exits 0. A repo cursor resumes the next run where this one stopped.
3. Unscoped runs scan only repos whose local checkout contains the dispatch system (`.agents/scripts/pulse-wrapper.sh`). An explicit `--repo` bypasses this gate.
4. The classification rationale reaches the log and the YES advisory comment.

Implementation notes, added during implementation:

- Items 3 and 4 were added from evidence. 69 of the runner's 70 pulse repos are product repos that can never host a fix-the-fixer task, yet each was listed every run and its issues were sent to the model. Separately, the live advisory on #38633 posted an empty `**Rationale:**`: `verdict=$(_classify_via_llm ...)` runs in a subshell, so the `RATIONALE` global never reached `cmd_check`. The classifier now prints `VERDICT<TAB>RATIONALE`.
- The cache check runs in `cmd_run` (`_scan_repo`), using title and body from the list call, so cached issues need no `gh issue view`. `cmd_check` still records verdicts, so explicit `check` calls refresh the cache.
- Measured: one real classification takes about 10s (`opencode run` spawn included). An unscoped dry-run over the real 70-repo config resolved to 1 repo and classified 4 issues in 44.5s with `stop=complete`, against previous runs that always timed out at 60s.

## Why

Evidence from one runner (`~/.aidevops/logs/pulse-stage-timings.log`, `pulse.log`, `pulse-wrapper.log`, 2026-11-16):

- `fix_the_fixer_detector` ran 48 times: 26 ended rc=124 at 61-63s (`worker_killed ... reason=stage_timeout_60s`), and the other 22 were 2s warm sentinel skips. **Every cold run timed out.**
- Each cold run classifies a few issues before the kill, but `NO` verdicts are not remembered. The next run re-classifies the same issues first: one managed-repo issue got `verdict=NO` in 4 consecutive runs and another in 3. Issues later in the iteration order are never reached.
- The kill also prevents `_log_run_summary`, so `~/.aidevops/cache/fix-the-fixer-detector-status.json` never exists, and `pulse-check-helper.sh` (`.current_state.fix_the_fixer_detector`) has no evidence to report.

Impact: dispatch-system issues miss the `fix-the-fixer` label and its extra worker observability (t3077), and every hour the detector spends about 60s of Pulse time plus repeated LLM calls with no new outcome.

## Tier

**Selected tier:** `tier:standard`. **Tier rationale:** a bounded change to one bash helper, plus extending its existing stubbed tests.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/pulse-fix-the-fixer-detector.sh`
  - Add `readonly VERDICT_CACHE_FILE="${HOME}/.aidevops/cache/fix-the-fixer-verdicts.tsv"`, with columns `slug<TAB>issue<TAB>content_sha256<TAB>verdict<TAB>epoch`.
  - Hash the same `CONTENT_KEY_JQ` projection (base64 of title + newline + body) in both paths. `_scan_repo` checks the cache before calling `cmd_check`, and `cmd_check` records the verdict.
  - After a `YES` or `NO` verdict, append the row. Write through a temp file plus `mv`, or append atomically, and cap the file at the last 2000 rows. Under `AIDEVOPS_FIX_THE_FIXER_DETECTOR_DRY_RUN=1`, do not write cache rows.
  - In `cmd_run`, read `AIDEVOPS_FIX_THE_FIXER_DETECTOR_BUDGET_SECONDS` (default 40, validated as a positive integer) and record the start time. Before each `cmd_check`, break out of both loops once the elapsed time reaches the budget, then fall through to `_log_run_summary`. Add `budget_exhausted` (true/false) to the summary JSON and the log line.
  - Update the header comment's Tunables list.
- `EDIT: .agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh` (or the sibling `test-pulse-fix-the-fixer-label.sh`, whichever already stubs `gh` and `PULSE_AI_RESEARCH_HELPER_OVERRIDE`). Add cases:
  - A second `run` over unchanged stubbed issues makes 0 stub LLM invocations (count invocations in a temp file).
  - Changing the stubbed body triggers one new invocation.
  - A stub that exits 2 (SKIP) is not cached, so the next run invokes it again.
  - With `AIDEVOPS_FIX_THE_FIXER_DETECTOR_BUDGET_SECONDS=1` and a stub that sleeps 2s, `run` exits 0 after at most one classification and writes the status file with `budget_exhausted:true`.

### Complete Write Surface

- **Callers/readers:** `pulse-wrapper-cycle-gates.sh:432` (`_pulse_run_fix_the_fixer_detector_if_stale`, unchanged) and `pulse-check-helper.sh:244` (reads the status file; the new optional `budget_exhausted` field must not break its jq).
- **Writers:** the new cache file under `~/.aidevops/cache/` (already a detector-owned directory, also used for the auth cooldown and status files).
- **Schemas/config:** none. The new env tunable defaults safely.
- **Generated/deployed mirrors:** deployed via `setup.sh`.
- **Cleanup/rollback:** revert the PR; the cache file is inert without the reader.

### Hazards and Compatibility

- The cache key includes the content hash, so an edited issue is always classified again. `YES` verdicts are cached as well, but the label check (`:501-509`) already skips labelled issues, so a cached YES on an unlabelled issue (label removed by a maintainer) must **not** re-apply the label. That respects the maintainer's removal.
- The budget must stay below `PULSE_FIX_THE_FIXER_TIMEOUT_SECONDS` (60). The implemented default is 40s, which leaves room for one in-flight classification (about 10s) plus the summary write.
- Keep the explicit `return 0`/`return 1`, `local var="$1"` and named-local argument conventions. The file uses `set -euo pipefail`, so capture return codes explicitly as `cmd_run` already does.

### Verification

```bash
bash .agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh
bash .agents/scripts/tests/test-pulse-fix-the-fixer-label.sh
bash .agents/scripts/tests/test-fix-the-fixer-observability.sh
bash .agents/scripts/tests/test-pulse-check-helper.sh
bash .agents/scripts/tests/test-ai-research-helper-oauth-pool.sh
shellcheck .agents/scripts/pulse-fix-the-fixer-detector.sh
.agents/scripts/linters-local.sh --changed
```

Post-deploy runtime check: within two hourly cold runs, `pulse-stage-timings.log` shows `fix_the_fixer_detector` rc=0 (not 124), and `~/.aidevops/cache/fix-the-fixer-detector-status.json` exists.

### Files Scope

- `.agents/scripts/pulse-fix-the-fixer-detector.sh`
- `.agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh`
- `.agents/scripts/tests/test-ai-research-helper-oauth-pool.sh` (its detector stub predated GH#36535's direct label lookup, and these two cases already failed on `main`)

## Acceptance Criteria

- [ ] A repeat run over unchanged issues makes zero LLM calls; an edited body is classified again; SKIP and SKIP_AUTH are never cached.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-fix-the-fixer-detector-auth-cooldown.sh"
  ```

- [ ] With the budget exhausted, `run` exits 0 and writes the status file with `budget_exhausted:true`; the repo cursor resumes the next run where this one stopped.
- [ ] Unscoped runs skip repos whose checkout lacks `.agents/scripts/pulse-wrapper.sh`; logged and advised rationales are non-empty.
- [ ] Regression: existing detector, label, observability and pulse-check tests still pass, and a removed `fix-the-fixer` label is not re-applied from a cached YES.
- [ ] ShellCheck is clean and `linters-local.sh --changed` passes.

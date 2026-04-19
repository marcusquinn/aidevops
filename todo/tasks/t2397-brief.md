# t2397: feat(fast-fail): age-out HARD STOP counter to auto-recover permanently-blocked issues

## Session origin

- Date: 2026-04-19
- Context: Diagnostic session — issue #19864 (t2380 CodeRabbit nits) and #19740 (fast-fail gate workflows) are both in `HARD STOP count=6>=5` state and will never dispatch again unless manually intervened. Pulse log confirms every pulse cycle logs `fast_fail_is_skipped ... HARD STOP count=6>=5` for these two issues.
- Sibling tasks: t2394 (CLAIM_VOID), t2395 (maintainer-gate exemption), t2396 (reassign normalization), t2398 (hot-deploy).

## What

`fast_fail_helper.sh` (or wherever `FAST_FAIL_HARD_STOP_THRESHOLD` is enforced) currently records failures monotonically — once an issue hits `count>=5` (HARD STOP), it never dispatches again. Add an age-based auto-reset: if the issue's most recent fast-fail record is older than N hours (default 24) AND the issue is still `status:available`, reset the counter to 0 on the next pulse cycle so dispatch can retry with fresh code.

## Why

**Root cause confirmed in production 2026-04-19.** Pulse log (`~/.aidevops/logs/pulse.log`):

```
fast_fail_is_skipped issue=19864 count=6 max=5 verdict=HARD STOP
fast_fail_is_skipped issue=19740 count=6 max=5 verdict=HARD STOP
```

Both issues are permanently blocked. In practice, many failures that accumulated the counter were transient (model-availability errors pre-t2392, cross-runner claim starvation, CI flakes) and have since been fixed upstream — but the counter doesn't know that. Manual recovery requires touching the counter file or posting specific labels, which operators rarely do.

**Design defect:** `FAST_FAIL_HARD_STOP_THRESHOLD` was introduced to prevent infinite dispatch loops on genuinely broken tasks (t2007/t2008 cost circuit breaker precedent). But "genuinely broken" and "transiently broken after now-fixed framework bug" are indistinguishable at time-of-failure. Only time differentiates them: after N hours, if no new failures arrived, the broken state is likely resolved.

**Precedent:** `circuit-breaker-helper.sh` already has a recovery-on-success path. The fast-fail counter lacks its twin: recovery-on-quiet.

## How

### Files to modify

- **EDIT**: `.agents/scripts/fast-fail-helper.sh` (likely location — verify with `grep -l HARD.STOP .agents/scripts/*.sh`).
  - Add new function `fast_fail_age_out` that:
    - Reads the fast-fail record file for `<issue, repo>` key
    - Checks `last_failure_ts` against current time
    - If `(now - last_failure_ts) >= FAST_FAIL_AGE_OUT_SECONDS` AND current count >= `FAST_FAIL_HARD_STOP_THRESHOLD`, reset count to 0 and update `last_reset_ts`
    - Log: `[pulse-wrapper] fast_fail_age_out: reset issue #${issue} count from ${old_count} to 0 (last failure at ${last_failure_ts}, ${hours}h ago)`

- **EDIT**: `.agents/scripts/pulse-wrapper.sh` — in the main pulse cycle, call `fast_fail_age_out` for each candidate issue before the existing `fast_fail_is_skipped` check.

- **EDIT**: `.agents/configs/defaults.conf` (or equivalent) — add new constant:
  ```
  FAST_FAIL_AGE_OUT_SECONDS=86400  # 24 hours
  FAST_FAIL_AGE_OUT_MIN_COUNT=5    # only age-out issues at or above HARD STOP threshold
  ```

### Reference pattern

- Model on `circuit-breaker-helper.sh` recovery logic — which already implements time-based auto-recovery for the global circuit breaker.
- Storage: fast-fail counter file likely lives at `~/.aidevops/.agent-workspace/fast-fail/${slug-safe}-${issue}.json` — verify and preserve the existing schema when adding `last_reset_ts`.
- Safety: age-out should NOT reset for issues that had a failure in the last hour (avoid thrashing on recurring same-root-cause failures).

### Safeguards

- Age-out only triggers for `status:available` issues — an actively-dispatched issue should stay on its current counter state.
- Log every age-out event; emit a one-time issue comment (marker-guarded) `Fast-fail counter auto-reset after 24h quiet period; pulse will retry dispatch.` so operators see when auto-recovery fires.
- Consider a hard ceiling: after 3 auto-resets on the same issue without a successful dispatch, apply `needs-maintainer-review` and stop. Prevents an infinitely-looping broken issue from burning worker tokens.

## Acceptance criteria

1. An issue at `fast_fail_count=6` with `last_failure_ts` older than 24h and `status:available` is reset to `count=0` on the next pulse cycle and dispatches normally.
2. An issue at `fast_fail_count=6` with `last_failure_ts=10m ago` is NOT reset (quiet-period check).
3. An issue at `fast_fail_count=3` (below HARD STOP) is NOT affected by age-out (safeguard: only apply to HARD STOP'd issues).
4. An issue at `fast_fail_count=6`, `status:in-progress` is NOT reset (only available-state issues get age-out).
5. After 3 consecutive auto-resets without a successful dispatch, the issue gets `needs-maintainer-review` label applied.
6. `fast_fail_age_out` emits a log line to `pulse-wrapper.log` when it fires.
7. Immediate effect: on first pulse cycle after deploy, #19864 and #19740 should be reset (they've been HARD STOP'd for >24h already).
8. `shellcheck` passes.

## Verification

```bash
# Regression test
.agents/scripts/tests/test-fast-fail-age-out.sh  # new test

# Live verification after deploy
tail -f ~/.aidevops/logs/pulse-wrapper.log | grep "fast_fail_age_out"

# Confirm #19864 and #19740 dispatch on next cycle
gh api repos/marcusquinn/aidevops/issues/19864 --jq '.labels[].name'
# Expected (post-fix, post-dispatch): status:queued or status:in-progress
```

## Context

- Related: t2007/t2008 cost circuit breaker (the original escalation design).
- Not the same as manual `sudo aidevops approve issue N` — age-out is autonomous, approval is human override.
- Priority: MEDIUM — unblocks 2 permanently-stuck issues immediately; prevents indefinite accumulation of stuck issues going forward.

# t2387 — Route no_work crashes to skip tier escalation

**Session origin:** interactive (2026-04-19 diagnostic pass on 17 open issues)

**Issue:** GH#19914

## What

When `worker-watchdog.sh` classifies a worker exit as `crash_type=no_work`
(the worker died during infrastructure setup — FD exhaustion, plugin init
crash, branch naming failure, auth refresh race — BEFORE ever reading the
target files), `escalate_issue_tier` in `worker-lifecycle-common.sh` still
runs the tier cascade at threshold=2 (`tier:simple` → `tier:standard` →
`tier:thinking` → NMR). This wastes progressively more expensive models on
the same underlying infrastructure failure.

Fix: when `crash_type == "no_work"`, skip tier escalation entirely. Keep the
issue at its current tier, post a diagnostic comment, and let the existing
circuit breakers (`cost-circuit-breaker-helper.sh`, `dispatch-dedup-stale.sh`,
stale-recovery) apply NMR after their own thresholds trip. Those breakers
already use distinct markers that t2386 (`_nmr_application_is_circuit_breaker_trip`)
recognises so `auto_approve_maintainer_issues` correctly preserves NMR.

## Why

**Failure mode observed in the 2026-04-19 diagnostic audit (issues #19733,
#19738, #19749):** 5 dispatches / 0 kills per issue. Workers start, claim,
exit cleanly without a PR. Watchdog logs them as `no_work`. Current
`escalate_issue_tier` behaviour:

1. First `no_work` crash → failure_count=1 → below threshold → no escalation
2. Second `no_work` crash → failure_count=2 → **escalates tier:simple → tier:standard**
3. Third `no_work` crash → failure_count=3 → no escalation (already past threshold)
4. ...but wait, failure_count keeps incrementing on each dispatch. If the
   issue gets stuck in a no_work loop it eventually hits `threshold*2` etc.
   Actually re-reading line 851: `if [[ "$failure_count" -ne "$threshold" ]]; then return 0; fi` — the
   function only escalates AT the threshold boundary, so it escalates exactly
   once per tier. Cascade progression needs another 2 failures at the new
   tier to trigger the next cascade step.

Regardless of the exact cascade geometry, the core problem is: no_work
failures are *infrastructure* problems. Throwing a more expensive model at
them does not help — the worker never even got to the model. The t2119 fix
already acknowledged this by skipping the body-quality gate on no_work.
This task completes that reasoning: skip the tier escalation too.

**Impact of the fix:** issues repeatedly failing with no_work stay at their
original tier (usually `tier:simple` or `tier:standard`). If the
infrastructure problem resolves (next pulse cycle the FD is free, the plugin
loads cleanly, the auth refresh succeeds), the retry can succeed at the
cheap tier. If the infrastructure problem persists, the existing
circuit-breaker helpers fire on retry frequency/cost thresholds and apply
NMR with markers t2386 preserves correctly.

## How

Edit `.agents/scripts/worker-lifecycle-common.sh` `escalate_issue_tier`
(currently ~lines 825-1014):

1. After the numeric/label validation (lines 832-848) and BEFORE the
   threshold gate (line 850), add a short-circuit branch:

   ```bash
   # t2387: no_work crashes are infrastructure failures. Tier escalation
   # is the wrong response — a more expensive model cannot fix an FD
   # exhaustion, a plugin init crash, or an auth refresh race. Skip tier
   # escalation entirely and let the circuit-breaker helpers (cost,
   # stale-recovery, dispatch-dedup-stale) apply NMR on retry frequency
   # thresholds. Their NMR markers are recognised by t2386
   # _nmr_application_is_circuit_breaker_trip so auto-approval preserves
   # the NMR correctly.
   if [[ "$crash_type" == "no_work" ]]; then
       _log_no_work_skip_escalation "$issue_number" "$repo_slug" \
           "$failure_count" "$reason"
       return 0
   fi
   ```

2. Add a new helper function `_log_no_work_skip_escalation` that:
   - Posts a one-time diagnostic comment (idempotent via marker
     `<!-- no-work-escalation-skip -->`) explaining that the cascade was
     skipped because infrastructure failures don't benefit from tier
     escalation.
   - Emits a structured log line so the pulse telemetry can track the
     skip rate.

3. Remove the now-dead `no_work` branch from the `crash_type_label` switch
   (lines 983-985) since that path is unreachable after the early return.
   Keep the `overwhelmed` and `partial` branches intact.

## Verification

1. **Unit test** at `.agents/scripts/tests/test-worker-reliability-self-heal.sh`
   (extend existing `test_escalate_skips_body_gate_on_no_work` pattern at
   line 233-270):

   ```bash
   test_escalate_skips_tier_cascade_on_no_work() {
       # Mock: issue with tier:simple label, failure_count=2 (threshold)
       # Call: escalate_issue_tier 42 fake/repo 2 "worker_exit_0" "no_work"
       # Expect: no gh edit, no tier:standard label added, diagnostic comment posted
   }
   ```

2. **Regression test:** confirm existing `overwhelmed` crash type still
   escalates at threshold=1 (existing test `test_escalate_body_gate_no_work_bypasses_gate`
   should remain green; add `test_escalate_skips_tier_cascade_on_no_work` as a
   new assertion).

3. **Local shellcheck:** `shellcheck .agents/scripts/worker-lifecycle-common.sh`.

## Acceptance Criteria

- [ ] `crash_type == "no_work"` short-circuits `escalate_issue_tier` before
  any tier label mutation.
- [ ] A diagnostic comment with marker `<!-- no-work-escalation-skip -->`
  is posted once per issue (idempotent via marker lookup).
- [ ] Existing `overwhelmed` threshold=1 behaviour unchanged.
- [ ] Existing `partial` / unclassified default threshold=2 behaviour
  unchanged.
- [ ] New unit test asserts no tier label change on no_work crashes.
- [ ] Shellcheck clean.

## Context

- **Companion fix:** t2386 (PR #19909) narrows NMR auto-approval to
  creation-defaults so circuit-breaker NMR applications are preserved.
  Together, t2386 and t2387 close the GH#19756-class auto-approval loop.
- **Related:** t2119 (body-quality gate skip on no_work) at
  worker-lifecycle-common.sh:930-933.
- **Evidence:** issues #19733, #19738, #19749 — 5 dispatches / 0 kills,
  cascaded to tier:thinking on infrastructure failures.

## PR Conventions

Leaf issue (not parent-task). Use `Resolves #19914` in PR body.

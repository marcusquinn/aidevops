# t2386: fix(nmr): preserve NMR when circuit breaker tripped

**Task ID:** `t2386` | **Status:** in-progress | **Estimate:** ~45m
**Logged:** 2026-04-19
**Session origin:** interactive session — pipeline failure-mode diagnosis (see session summary on #19756)
**Tags:** `framework` `bug` `dispatch` `circuit-breaker`

## What

Split `_nmr_application_has_automation_signature()` in `pulse-nmr-approval.sh` so that circuit-breaker trip markers (`stale-recovery-tick:escalated`, `cost-circuit-breaker:fired`, `circuit-breaker-escalated`) **preserve** `needs-maintainer-review`, while creation-time default markers (`source:review-scanner`, `review-followup` label) still auto-clear. Stops the infinite auto-approval loop observed on #19756 (22 watchdog kills + 5 auto-approval / re-NMR cycles in one afternoon, zero PRs produced).

## Why

`auto_approve_maintainer_issues()` treats ALL automation signatures — creation-defaults AND breaker trips — as "safe to auto-approve and re-dispatch." This defeats the very safety mechanism the breakers exist for:

1. Worker crash-loops on #19756 (task body is structurally unimplementable — 147 markdown-lint violations across one file, too large for a single session).
2. `dispatch-dedup-stale.sh` hits threshold 2/2 → applies `needs-maintainer-review` + `<!-- stale-recovery-tick:escalated -->` comment.
3. Next pulse cycle: `auto_approve_maintainer_issues` sees `issue_author == maintainer` + automation signature → strips NMR, adds `auto-dispatch`.
4. Worker re-dispatches → crashes → GOTO 2.

Evidence on #19756 at diagnosis time (2026-04-19):

```
13:14:58  Auto-approved: maintainer is author, NMR applied by automation. Stale recovery tick reset.
13:40:08  Auto-approved: maintainer is author, NMR applied by automation. Stale recovery tick reset.
14:04:47  Auto-approved: maintainer is author, NMR applied by automation. Stale recovery tick reset.
14:28:17  Auto-approved: maintainer is author, NMR applied by automation. Stale recovery tick reset.
14:52:36  Auto-approved: maintainer is author, NMR applied by automation. Stale recovery tick reset.
```

Five identical auto-approvals every ~25 minutes. Each triggered a worker dispatch that then hit rate-limit backoff or `no_work` crash. The stale-recovery circuit breaker never got to STAY tripped long enough for human review.

## How

### 1. `pulse-nmr-approval.sh`

**Narrow `_nmr_application_has_automation_signature()` semantics.** The function currently detects four markers as "safe to auto-approve." Keep only two:

- `source:review-scanner` comment marker → creation-default
- `review-followup` / `source:review-scanner` label → creation-default

Remove `stale-recovery-tick:escalated`, `cost-circuit-breaker:fired`, `circuit-breaker-escalated` from this function. Those are breaker trips, not defaults.

**Add new `_nmr_application_is_circuit_breaker_trip()`** that detects the three breaker markers. Used by `_nmr_applied_by_maintainer()` for diagnostic logging.

**Update `_nmr_applied_by_maintainer()` decision tree:**

```
if actor != maintainer       → return 1 (not a maintainer hold, auto-approve OK)
if creation-default sig      → return 1 (scanner default, auto-approve OK)
if circuit-breaker trip sig  → return 0 (breaker tripped, PRESERVE NMR, log human-approval path)
else                         → return 0 (genuine manual hold, PRESERVE NMR)
```

Both latter cases return 0, but with distinct log lines so the pulse log tells operators whether a stuck NMR is a real human-held issue or a tripped breaker awaiting `sudo aidevops approve issue N`.

### 2. `tests/test-pulse-nmr-automation-signature.sh`

- **Invert** `test_detects_stale_recovery_escalation_marker` and `test_detects_cost_circuit_breaker_marker` — they currently assert the BUG behavior (breaker markers match the creation-default signature). After the fix, both should assert that the creation-default check returns 1 (NOT found), and a new companion check against `_nmr_application_is_circuit_breaker_trip` returns 0 (found).
- **Add** `test_19756_loop_prevention`: simulates the exact sequence — issue authored by maintainer, NMR label applied by maintainer token, adjacent comment contains `stale-recovery-tick:escalated`. Asserts `_nmr_applied_by_maintainer` returns 0 (preserve NMR) so auto-approve is suppressed.

### 3. `prompts/build.txt`

Add a one-paragraph rule under the existing "Cryptographic issue/PR approval" section: **automation signatures split into "creation defaults" (auto-clear) and "breaker trips" (preserve NMR; require `sudo aidevops approve issue N`)**. Cite #19756 as the canonical failure.

### 4. Immediate remediation

After the fix merges:

- Post explanatory comment on #19756 documenting the loop + referencing this task.
- Do NOT auto-approve — this issue genuinely needs the maintainer to decide whether the task (147 markdownlint violations in one file) is workable as a single task or needs decomposition.

## Acceptance criteria

- [ ] `_nmr_application_has_automation_signature` returns 1 (NOT a creation-default) when only `stale-recovery-tick:escalated` or `cost-circuit-breaker:fired` markers are present
- [ ] `_nmr_application_has_automation_signature` still returns 0 for `source:review-scanner` or `review-followup` label
- [ ] New `_nmr_application_is_circuit_breaker_trip` returns 0 for breaker markers, 1 otherwise
- [ ] `auto_approve_maintainer_issues` preserves NMR on breaker-tripped issues; logs "NMR preserved — circuit breaker tripped"
- [ ] `tests/test-pulse-nmr-automation-signature.sh` passes with updated expectations
- [ ] New regression test for the #19756 loop passes
- [ ] `shellcheck .agents/scripts/pulse-nmr-approval.sh` clean
- [ ] `prompts/build.txt` documents the split semantics

## Files

- **EDIT**: `.agents/scripts/pulse-nmr-approval.sh:247-378` (function + docstring; add new function; update decision tree)
- **EDIT**: `.agents/scripts/tests/test-pulse-nmr-automation-signature.sh` (invert two tests; add regression test)
- **EDIT**: `prompts/build.txt` (under Cryptographic approval section)

## Tier checklist

- [x] 3+ files with clear edits (not subjective)
- [x] All files <500 lines in scope (pulse-nmr-approval.sh is 487)
- [x] No cross-package changes
- [x] No judgment calls — decision tree is deterministic
- [x] 8 acceptance criteria
- [x] Can be verified via shellcheck + test suite
- → `tier:standard` (borderline simple, but the test inversions require careful reading)

## Context

- Diagnostic session: 2026-04-19 pipeline-failure-mode review
- Related: t1331 (supervisor circuit breaker), t2007 (cost breaker), t2008 (stale recovery), GH#18538 (review scanner), GH#18671 (original GH token / automation signature pairing)
- Canonical failure: #19756 (t2240 markdownlint cleanup — 22 kills, 5 auto-approve cycles)

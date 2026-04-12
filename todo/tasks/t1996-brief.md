---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1996: dispatch-dedup: generalize is_assigned() to block on any worker self-assignment, not just origin:interactive

## Origin

- **Created:** 2026-04-12
- **Session:** claude-code:interactive
- **Created by:** marcusquinn (human) via ai-interactive
- **Parent task:** none
- **Conversation context:** While retagging t1992/t1993 for worker dispatch, observed that the multi-operator pulse setup creates a window where two operators' pulses could race to claim the same `auto-dispatch` issue. The existing `is_assigned()` guard at `dispatch-dedup-helper.sh:676` already handles assignee-blocking for "any other login", but the user's framing was: "labels should gate against another worker self-assigning something that's already being worked on — so it's not just the label in the logic, but the label and assignee". This task audits all dispatch decision points to ensure label + assignee are checked together as a combined signal at every point, not just inside `is_assigned()`.

## What

Audit every code path that decides whether to dispatch a worker against an issue and ensure each one applies the **combined label-and-assignee gate**: if an issue carries any active-claim status label (`status:queued`, `status:in-progress`, `status:in-review`, `status:claimed`) AND has any non-self assignee, no other pulse may dispatch a worker against it — full stop, regardless of any other label state (auto-dispatch, tier, origin).

The current `is_assigned()` at `.agents/scripts/dispatch-dedup-helper.sh:676` already implements most of this for the explicit assignee-check entry point. The risk is that other dispatch decision sites — `list_dispatchable_issue_candidates_json` in `pulse-repo-meta.sh`, the deterministic fill-floor in `pulse-dispatch-engine.sh`, the worker dispatch ledger in `pulse-dispatch-core.sh` — may apply label-only filters without round-tripping through `is_assigned()`, creating windows where the combined check is bypassed.

Scope of work:

1. **Audit pass**: locate every code path that emits a dispatch claim (search for `gh issue edit ... --add-assignee`, `status:queued`, `dispatch-dedup-helper.sh is-assigned`, `list_dispatchable_issue_candidates_json`, `apply_deterministic_fill_floor`, `dispatch_with_dedup`). For each path, document whether the label+assignee combined check is applied.
2. **Fix gaps**: any path that does not call `is_assigned()` (or equivalent inline label+assignee check) before claiming must be amended to do so. If `is_assigned()` itself has a hole (e.g., an active-claim status label set with no assignee — the degraded state), tighten its logic.
3. **Stronger test coverage**: add regression tests that simulate the multi-operator race — two pulses, the same target issue, the second pulse must observe the first pulse's claim-and-assign and refuse to dispatch.
4. **Document the canonical rule** in `dispatch-dedup-helper.sh` header and in `AGENTS.md` "Auto-Dispatch and Completion" section: "the dispatch dedup signal is `(active status label) AND (non-self assignee)` — both required, neither sufficient alone".

## Why

The canonical scenario is the multi-operator race observed during this session:

- Issue #18420 (t1993) was filed with `auto-dispatch` + no assignee at 21:03:14Z
- alex-solovyev's pulse claimed it at 21:08:35Z (assignee=alex-solovyev, status:queued, origin:worker)
- A worker (PID 30469) started running at 21:09:01Z

This itself worked correctly — the first pulse won the race via the atomic assign-and-label step. The risk is that **after** alex-solovyev's pulse claimed, my own machine's pulse on its next cycle could observe the issue and try to claim it again. In the current code, the `is_assigned()` guard blocks this because alex-solovyev is "any other login != self". Good.

But the failure mode the user is concerned about is more subtle: a code path that checks for `status:queued` *as a positive signal* without checking the assignee, and uses that to DECIDE not to claim. Or the inverse: a code path that finds `auto-dispatch` and dispatches without checking the assignee. Today's `is_assigned()` is the gatekeeper, but only IF every dispatch site routes through it. The audit confirms or refutes that.

The complementary protection: the label without an assignee is ALSO a degraded state — if an issue has `status:in-progress` but nobody is assigned, that's a leak from a previous worker that died without releasing the claim. Such issues should be considered claim-able again (after a stale recovery pass), but until that pass runs they must NOT be picked up by a new pulse, because the missing assignee means we have no way to know if the previous worker is still running. This is the "label and assignee together" rule the user articulated.

The session had a concrete near-miss: t1992 (#18418) had `auto-dispatch` momentarily stripped and re-added by the issue-sync workflow. During the 7-minute strip window, no pulse picked it up — but the existence of that window suggests label state can flutter under multi-operator conditions, and any dispatch logic that assumes labels-alone are dispositive is fragile.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** → no (audit pass touches several pulse-* scripts; fix scope depends on findings)
- [ ] **Complete code blocks for every edit?** → no (audit determines what gets edited)
- [ ] **No judgment or design decisions?** → no (which gaps are real bugs vs intentional? when is a label-only check legitimate?)
- [ ] **No error handling or fallback logic to design?** → no (degraded state handling, stale assignment recovery interactions)
- [ ] **Estimate 1h or less?** → no (~3h including audit + fixes + tests)
- [ ] **4 or fewer acceptance criteria?** → no (6 criteria)

**Selected tier:** `tier:standard`

**Tier rationale:** Audit + targeted fixes + new test coverage. Requires understanding the dispatch lifecycle across multiple pulse modules (`dispatch-dedup-helper.sh`, `pulse-repo-meta.sh`, `pulse-dispatch-engine.sh`, `pulse-dispatch-core.sh`). Not novel design, but enough surface area that `tier:simple` would miss the cross-cutting concerns. Sonnet should handle it well.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/dispatch-dedup-helper.sh:596-725` — `_has_active_claim()` and `is_assigned()`. Verify the active-claim signal is conjoined with assignee presence; if a label-only path exists, document it explicitly.
- `EDIT: .agents/scripts/pulse-repo-meta.sh:140-170` — `list_dispatchable_issue_candidates_json()`. Audit the jq filter for label-only checks; if it filters on `auto-dispatch` without consulting assignees, that's an issue.
- `EDIT: .agents/scripts/pulse-dispatch-core.sh` — search for direct `gh issue edit --add-assignee` or `--add-label "status:queued"` calls. Each must be preceded by an `is_assigned()` check or equivalent.
- `EDIT: .agents/scripts/pulse-dispatch-engine.sh` — `apply_deterministic_fill_floor` and adjacent dispatch sites.
- `NEW: .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` — regression test simulating two pulses racing for the same issue.
- `EDIT: .agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh` — extend if existing assertions don't cover the combined-signal cases identified by the audit.
- `EDIT: .agents/AGENTS.md` "Auto-Dispatch and Completion" — append a paragraph stating the canonical rule.

### Implementation Steps

1. **Audit pass** — list every dispatch decision site:

   ```bash
   # Sites that ASSIGN workers
   rg -n 'gh issue edit.*--add-assignee|--add-label "status:(queued|in-progress|in-review|claimed)"' .agents/scripts/

   # Sites that CHECK whether to dispatch
   rg -n 'is_assigned|_has_active_claim|list_dispatchable_issue_candidates_json|dispatch_with_dedup' .agents/scripts/

   # Sites that look at status:* labels
   rg -n '"status:queued"|"status:in-progress"|"status:in-review"|"status:claimed"' .agents/scripts/
   ```

   Build a table: `code path | currently checks | desired check | gap`.

2. **Fix gaps**: for each entry where the code path emits a dispatch but doesn't call `is_assigned()` (or apply an equivalent label+assignee combined check), add the call. Preserve the existing single-call paths — most of the work is wiring the audit findings, not redesigning the function.

3. **Tighten `_has_active_claim()` if needed**: today it returns `true` if any active-claim label is present. Consider whether it should also require assignee presence to return `true` — if a label is set without an assignee, that's a degraded state and should arguably be `false` (so the stale-recovery pass can clean it up). Decision: discuss with the user before changing the semantic; default is to leave `_has_active_claim()` as-is and add the assignee dimension at the call sites.

4. **Add the multi-operator regression test**:

   ```bash
   # test-dispatch-dedup-multi-operator.sh
   # Scenario: simulate two pulses (mar, alex) on the same issue
   #   1. Both query is_assigned("18420", "owner/repo", "mar") → both get "false" (no assignee)
   #   2. mar calls "gh issue edit --add-assignee mar --add-label status:queued"
   #   3. alex queries is_assigned again — must return TRUE (assignee != alex)
   #   4. alex's dispatch must be blocked at every entry point
   # Use stubbed gh that records assignment ordering.
   ```

   Minimum 4 assertions:
   - Race winner gets dispatch, race loser blocks
   - Issue with status:queued + no assignee is treated as degraded (stale recovery candidate, not active claim)
   - Issue with active assignee + no status label still blocks (assignee alone is enough for a worker user)
   - Owner/maintainer assignee + active status label blocks correctly (existing GH#18352 case)

5. **Update AGENTS.md** — append to the "**`origin:interactive` also skips pulse dispatch (GH#18352)**" paragraph:

   > **General rule (t1996):** the dispatch dedup signal is `(active status label) AND (non-self assignee)` — both required, neither sufficient alone. Any code path that emits a dispatch claim must consult `dispatch-dedup-helper.sh is_assigned` (or apply the equivalent combined check inline) before assigning a worker. Label-only or assignee-only filters are not safe in multi-operator conditions.

### Verification

```bash
shellcheck .agents/scripts/dispatch-dedup-helper.sh \
  .agents/scripts/pulse-repo-meta.sh \
  .agents/scripts/pulse-dispatch-core.sh \
  .agents/scripts/pulse-dispatch-engine.sh \
  .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh
bash .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh
bash .agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
```

## Acceptance Criteria

- [ ] Audit table committed to the PR description listing every dispatch decision site, current check, desired check, and gap status.
  ```yaml
  verify:
    method: manual
    prompt: "PR description contains an audit table with at least 5 rows covering dispatch-dedup-helper.sh, pulse-repo-meta.sh, pulse-dispatch-core.sh, pulse-dispatch-engine.sh, and the deterministic fill-floor."
  ```
- [ ] Every dispatch decision site that emits a worker assignment routes through `is_assigned()` (or applies an equivalent inline combined check).
  ```yaml
  verify:
    method: codebase
    pattern: "is_assigned"
    path: ".agents/scripts/pulse-dispatch-core.sh"
  ```
- [ ] Regression test `test-dispatch-dedup-multi-operator.sh` exists with 4+ assertions covering: race winner/loser, degraded state handling, assignee-without-label, label-with-non-self-assignee.
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh"
  ```
- [ ] `AGENTS.md` documents the canonical rule "(active status label) AND (non-self assignee)".
  ```yaml
  verify:
    method: codebase
    pattern: "active status label.*non-self assignee|t1996"
    path: ".agents/AGENTS.md"
  ```
- [ ] `shellcheck` clean on all touched scripts.
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/dispatch-dedup-helper.sh .agents/scripts/pulse-repo-meta.sh .agents/scripts/pulse-dispatch-core.sh .agents/scripts/pulse-dispatch-engine.sh"
  ```
- [ ] `test-dispatch-dedup-helper-is-assigned.sh` and `test-pulse-wrapper-characterization.sh` still pass (no regression).
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh && bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh"
  ```

## Context & Decisions

- **Existing protection that already works:** `is_assigned()` at line 676 already returns "blocked" for any non-self assignee under most conditions. This task is *defensive hardening* — make sure every entry point goes through that gate. It is NOT a claim that `is_assigned()` is broken in isolation.
- **The "label and assignee" combined signal:** the user's exact framing was that the dedup logic must consider both, not one or the other. The audit will reveal whether any code path violates that.
- **Stale recovery interaction:** if an issue has `status:in-progress` but no assignee, that's a worker death (the worker terminated before it could update state). The stale-recovery pass at `pulse-dispatch-core.sh` already handles this. The dedup gate must not interfere — degraded state should NOT be treated as "actively claimed" because that would prevent stale recovery from clearing it.
- **Why not simply call `is_assigned()` from inside `list_dispatchable_issue_candidates_json`:** the candidates list is built from a single jq expression on a batch GraphQL response — calling `is_assigned()` per candidate would require an additional `gh issue view` call per item, which is expensive. The fix may need to embed the equivalent combined check inside the jq filter (`labels` and `assignees` are both available in the GraphQL response).
- **Ruled out:**
  - *Reverting `is_assigned()` to be even stricter (block on any assignee regardless of status)* — this re-introduces the queue starvation bug GH#10521 fixed. Owner-as-passive-assignee is a valid state.
  - *Adding a global mutex via `gh issue lock`* — heavy-handed and breaks normal contributor workflows.

## Relevant Files

- `.agents/scripts/dispatch-dedup-helper.sh:596-725` — `_has_active_claim()`, `is_assigned()`
- `.agents/scripts/pulse-repo-meta.sh:140-170` — `list_dispatchable_issue_candidates_json()`
- `.agents/scripts/pulse-dispatch-core.sh` — `dispatch_with_dedup`, claim-and-assign sites
- `.agents/scripts/pulse-dispatch-engine.sh` — `apply_deterministic_fill_floor`
- `.agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh` — existing tests to extend
- `.agents/AGENTS.md` — "Auto-Dispatch and Completion" section
- Concrete repro session: this conversation, where t1993/#18420 dispatch race was observed (alex-solovyev claimed at 21:08:35Z) with the existing protection working correctly

## Dependencies

- **Blocked by:** none
- **Blocks:** none directly; closes a defensive gap that becomes critical as the multi-operator pulse fleet grows
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Audit pass: enumerate dispatch decision sites | 30m | rg + manual review |
| Build the audit table for the PR | 20m | |
| Fix any gaps found | 60m | Scope depends on audit |
| Write multi-operator regression test | 50m | Stubbed gh, race simulation |
| AGENTS.md doc update | 10m | One paragraph |
| Shellcheck + characterization runs | 10m | |
| **Total** | **~3h** | |

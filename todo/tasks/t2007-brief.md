<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2007: dispatch hardening — cost-per-issue circuit breaker

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** Tier B systemic fix from the GH#18356 root-cause analysis (the broader incident that motivated t1986).
- **Conversation context:** During t1962 Phase 3, the alex-solovyev pulse dispatched two opus-4-6 workers to the parent task GH#18356, burning ~20K tokens with zero useful output. t1986 closed the parent-task hole. This task closes a separate hole: even for legitimate (non-parent) tasks, a worker can fail repeatedly and rack up unbounded token cost without anyone noticing. The brief I gave at the t1962 closing summary listed this as "Tier B" follow-up.

## What

Implement a per-issue cumulative token cost circuit breaker. Track tokens spent across all worker attempts on each issue (extract from existing signature footers). When the cumulative spend exceeds a tier-appropriate budget with no merged PR, auto-apply `needs-maintainer-review` to halt further dispatch.

**Tier budgets:**

| Tier | Budget | Rationale |
|---|---:|---|
| `tier:simple` | 30,000 tokens | ~3× a typical haiku run |
| `tier:standard` | 100,000 tokens | ~3× a typical sonnet run |
| `tier:reasoning` | 300,000 tokens | ~3× a typical opus run |

(Final values should be calibrated against current observed spend distributions — see "How" below.)

When the breaker fires:
1. Apply `needs-maintainer-review` label (protected, blocks dispatch via existing maintainer-gate workflow)
2. Post a comment on the issue: `🛑 Cost circuit breaker fired: cumulative spend NNNK tokens across M attempts exceeds tier:X budget of NNNK. Maintainer review required before further dispatch.`
3. Skip dispatch on subsequent pulse cycles (the `needs-maintainer-review` label is enough — no separate state file needed)

## Why

- **Observed cost in this session:** ~30K opus tokens burned on GH#18356 across 2 attempts. Without the cap, this could have continued indefinitely until manual intervention.
- **t1986 closes the parent-task case** but doesn't help when classification is right but the work is genuinely unimplementable, the model is stuck in a loop, or the issue has a hidden blocker.
- **Cost discipline matters more as the framework scales** — multiple runners + tier:reasoning + reasoning models = real money. A circuit breaker is the standard pattern for this class of problem.
- **Existing telemetry suffices:** signature footers in worker comments already include token spend. We don't need new instrumentation, just aggregation.

## Tier

`tier:reasoning`. This is architectural design work, not a mechanical fix. The worker needs to:
1. Decide WHERE the breaker check fires in the dispatch flow (before claim? after claim, before launch? after launch?)
2. Decide HOW to aggregate spend (parse signature footers from `gh issue view --comments`? Maintain a state file? Use issue labels as memory?)
3. Calibrate budgets against actual spend distributions (read recent merged PR comments for token counts)
4. Decide failure mode for the aggregation layer (fail-open: if we can't compute spend, allow dispatch; fail-closed: block on uncertainty)

These decisions cascade — none of them are obvious. Sonnet might guess wrong; opus is appropriate.

### Tier checklist

- [ ] **2 or fewer files to modify?** — likely 3-4: dispatch-dedup-helper.sh, pulse-dispatch-core.sh, possibly a new helper, plus tests
- [ ] **Complete code blocks for every edit?** — no, the design is open
- [ ] **No judgment or design decisions?** — many (4 listed above)
- [ ] **No error handling or fallback logic to design?** — fail-open vs fail-closed is a design call
- [ ] **Estimate 1h or less?** — estimated 4-6h
- [ ] **4 or fewer acceptance criteria?** — 7 below

0/6 → `tier:reasoning`

## How

### Phase 1 — instrument & calibrate (read-only investigation, ~1h)

Before writing code, gather data:

```bash
# For all merged PRs in the last 30 days, extract token counts from signature footers
gh pr list --state merged --search "merged:>$(date -v-30d +%Y-%m-%d)" --json number,title --limit 100 > /tmp/recent-prs.json

# For each PR, fetch comments and grep signature footers for token counts
# Signature footer format (see gh-signature-helper.sh): includes "tokens=NNNK" or similar
for pr in $(jq -r '.[].number' /tmp/recent-prs.json); do
  gh pr view "$pr" --repo marcusquinn/aidevops --comments | grep -oE 'tokens?[=:][0-9]+' | head -1
done > /tmp/spend-distribution.txt

# Compute percentiles per tier
# Use the resulting distribution to validate the proposed budgets (30K/100K/300K)
```

Document the distribution in the PR body. If P95 spend is wildly different from the proposed budget, adjust.

### Phase 2 — design (~30m, document in PR body)

Decide:

1. **Where the check fires.** Recommended: in `is_assigned()` or alongside it in `dispatch-dedup-helper.sh`, AFTER the parent-task check (which is now in place from t1986) but BEFORE the assignee check. This makes it part of the dedup layer chain that already reports blocking reasons via stdout.
2. **How to aggregate spend.** Recommended: parse signature footers from `gh issue view --comments` JSON. No new state file. Cache the per-issue aggregate in `~/.aidevops/.agent-workspace/cache/cost-aggregates/<issue>.json` with TTL=15m if performance matters.
3. **Failure mode.** Recommended: fail-open. If spend can't be computed (no comments yet, gh API failure, parse error), allow dispatch. The breaker is a safety net, not a hard gate.
4. **Tier resolution.** The dispatch-dedup-helper already knows the tier from the issue's `tier:*` label. Use that.

### Phase 3 — implement (~2h)

1. Add a new function `_check_cost_budget()` in `dispatch-dedup-helper.sh`. Takes (issue_number, repo_slug, tier). Returns:
   - 0 + stdout `COST_BUDGET_EXCEEDED (spent=NNNK budget=NNNK)` → blocked
   - 1 → safe to dispatch
2. Wire into `is_assigned()` after the parent-task check, before assignee query. Same emit-and-return-0 pattern as `PARENT_TASK_BLOCKED`.
3. Add a new CLI subcommand `dispatch-dedup-helper.sh check-cost-budget <issue> <repo> <tier>` for testability.
4. Add the post-block side effects (label + comment) — these may live in a separate function `_apply_cost_breaker_side_effects()` called from the dispatch layer that observes the COST_BUDGET_EXCEEDED signal.

### Phase 4 — test (~1h)

New test file `.agents/scripts/tests/test-cost-circuit-breaker.sh`. Pattern from `test-parent-task-guard.sh`:
- Stub `gh issue view --comments` to return synthetic comments with various spend totals
- Assert: spend < budget → allow, spend > budget → block with COST_BUDGET_EXCEEDED signal, no comments → allow (fail-open)
- Assert: tier:simple budget enforced for tier:simple issue, tier:reasoning budget for tier:reasoning issue
- Assert: side-effect application (label + comment) happens once, not on every cycle

### Phase 5 — calibration follow-up

After 1 week of running, review which issues hit the breaker. If too aggressive (too many false-positives blocking legitimate iteration), raise budgets. If too lax (real cost incidents slip through), lower them. Track in a comment on this task or a follow-up issue.

## Acceptance Criteria

- [ ] Spend distribution analysis documented in PR body (P50/P90/P95 per tier from last 30 days of merged PRs)
- [ ] `_check_cost_budget()` implemented in `dispatch-dedup-helper.sh`
- [ ] CLI subcommand `check-cost-budget` exposed for testability
- [ ] Wired into dispatch flow at the agreed insertion point (PR body explains where and why)
- [ ] New test file `tests/test-cost-circuit-breaker.sh` with at least 6 assertions covering: under-budget allow, over-budget block, no-comments fail-open, gh API error fail-open, per-tier budget enforcement, side-effect idempotency
- [ ] Existing tests still pass (characterization, parent-task-guard, terminal-blockers, main-commit-check)
- [ ] PR body documents the budget rationale and the calibration plan

## Relevant Files

- `.agents/scripts/dispatch-dedup-helper.sh:676` — `is_assigned()` (insertion point reference)
- `.agents/scripts/tools/git/gh-signature-helper.sh` — signature footer format reference
- `.agents/scripts/tests/test-parent-task-guard.sh` — test pattern reference
- `.agents/configs/dispatch-cost-budgets.conf` (NEW) — tier budget config (allows tuning without code changes)

## Dependencies

- **Blocked by:** none
- **Blocks:** dispatch cost confidence at scale
- **Related:** t1986 (parent-task guard, just merged — sibling dispatch-hardening), t2008 (stale-recovery escalation), t2009 (cross-runner doc)

## Estimate

~5h: 1h calibration + 30m design + 2h implement + 1h test + 30m PR cycle + observation buffer.

## Out of scope

- Killing already-running workers that exceed budget (separate concern: requires cross-runner kill signal)
- Per-PR cost tracking (this is per-ISSUE; PRs are the byproduct)
- Token cost attribution to specific models or providers (the budget is total)

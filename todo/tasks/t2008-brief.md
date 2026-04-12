<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2008: dispatch hardening — stale-recovery escalation after N consecutive cycles

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** Tier C systemic fix from the GH#18356 root-cause analysis
- **Conversation context:** During t1962 Phase 3, GH#18356 went through repeated stale-recovery cycles: alex-solovyev's pulse would dispatch, claim, fail silently, stale-recovery would unassign and reset to `status:available`, then the next cycle would re-dispatch. Loop continued until manual intervention. t1986 closes the parent-task case via the unconditional dispatch block; this task closes the same loop for non-parent issues that simply can't be implemented.

## What

Add a counter to the stale-recovery path so that after N consecutive recoveries (default 2) without producing a PR, the recovery STOPS resetting to `status:available` and instead applies `needs-maintainer-review`. The issue then waits for a human.

**Detection signal:** stale-recovery already runs in the existing flow (see `dispatch-dedup-helper.sh` "stale assignment recovery" path that emits `STALE_RECOVERED`). We add a per-issue counter that increments each time stale recovery fires for the same issue, and resets when the issue produces a PR (open or merged) or gets a fresh worker comment.

**Threshold:** 2 consecutive recoveries with no PR → escalate. Configurable via `.agents/configs/dispatch-stale-recovery.conf` (new file).

## Why

- **Observed loop in this session:** GH#18356 stale-recovered twice (16:19 and 16:59 timestamps in the event log) and would have continued until I manually intervened with `needs-maintainer-review`.
- **Stale recovery is correct for transient failures** (network blip, runner crash, model timeout) but wrong for persistent failures (work is unimplementable, hidden blocker, brief is wrong).
- **2 cycles is enough signal:** if stale recovery fires twice in a row without a PR, the third attempt is wasted compute. The same model is going to fail the same way.
- **t1986 + t2007 + t2008 form a complete cost-control story:** parent tasks never dispatch (t1986), normal tasks have a token budget (t2007), and tasks that don't progress get bounced to maintainer review (t2008). All three layers needed to reliably stop runaway dispatch.

## Tier

`tier:standard`. Smaller scope than t2007 (the cost circuit breaker). The design is mostly clear: counter + threshold check. Worker still needs to decide where the counter lives, but the rest is mechanical.

### Tier checklist

- [ ] **2 or fewer files to modify?** — likely 3: dispatch-dedup-helper.sh, possibly a new state file helper, plus tests
- [ ] **Complete code blocks for every edit?** — partial
- [ ] **No judgment or design decisions?** — moderate (counter storage location, reset semantics)
- [x] **No error handling or fallback logic to design?** — straightforward
- [ ] **Estimate 1h or less?** — estimated 2-3h
- [x] **4 or fewer acceptance criteria?** — 5 below (just over)

`tier:standard`.

## How

### Counter storage decision

Three options:

1. **Issue label.** Apply `stale-recovery-count:N` label after each recovery. **Pros:** durable, visible, no extra storage. **Cons:** labels aren't designed for counter semantics; reconciliation may strip them; pollutes the label set.
2. **Issue comment.** Each stale recovery posts a `STALE_RECOVERY_TICK N/2` comment. **Pros:** durable, auditable, naturally part of the issue history. **Cons:** noisy on the issue thread.
3. **Local state file.** `~/.aidevops/.agent-workspace/cache/stale-recovery-counts.json` keyed by repo+issue. **Pros:** clean, fast. **Cons:** not cross-runner; each runner has its own count, so escalation only fires when ONE runner has done 2 consecutive recoveries.

**Recommendation:** option 2 (comment) for cross-runner correctness. The comment is the canonical signal that any runner can read. Use a structured marker `<!-- stale-recovery-tick:N -->` that's machine-readable and out of the way.

### Implementation sketch

In the existing stale-recovery path in `dispatch-dedup-helper.sh`:

```bash
# After unassigning the stale claimant:
local prior_ticks
prior_ticks=$(gh issue view "$issue_number" --repo "$repo_slug" --comments --json comments \
  --jq '[.comments[] | select(.body | contains("<!-- stale-recovery-tick:"))] | length' 2>/dev/null || echo 0)

# Check whether a PR has been produced since the last tick (resets the counter)
local pr_count_since_last_tick
pr_count_since_last_tick=$(...)  # gh pr list --search "linked-issue:$issue_number created:>$last_tick_time"

if [[ "$pr_count_since_last_tick" -gt 0 ]]; then
    # Reset
    gh issue comment "$issue_number" --repo "$repo_slug" --body "<!-- stale-recovery-tick:0 (reset after PR) -->"
elif [[ "$prior_ticks" -ge "$STALE_RECOVERY_THRESHOLD" ]]; then
    # Escalate
    gh issue edit "$issue_number" --repo "$repo_slug" --add-label "needs-maintainer-review"
    gh issue comment "$issue_number" --repo "$repo_slug" --body "🛑 Stale recovery threshold (${STALE_RECOVERY_THRESHOLD}) reached without producing a PR. Marking for maintainer review."
    return 0
else
    local next=$((prior_ticks + 1))
    gh issue comment "$issue_number" --repo "$repo_slug" --body "<!-- stale-recovery-tick:${next} -->"
    # Continue with the existing recovery (unassign, reset to available, etc.)
fi
```

### New config file

`.agents/configs/dispatch-stale-recovery.conf`:
```bash
# Threshold for stale-recovery escalation (t2008)
# After N consecutive stale recoveries without a PR, the issue is marked
# `needs-maintainer-review` instead of being reset to `status:available`.
STALE_RECOVERY_THRESHOLD=2
```

### Verification

```bash
bash -n .agents/scripts/dispatch-dedup-helper.sh
.agents/scripts/dispatch-dedup-helper.sh --help

# New test: tests/test-stale-recovery-escalation.sh
# Pattern from test-parent-task-guard.sh — stub gh, simulate the full sequence:
#   Tick 1 → comment posted, no escalation
#   Tick 2 → comment posted, no escalation (still under threshold)
#   Tick 3 (= threshold N=2 met on the 3rd attempt) → escalation comment + needs-maintainer-review label
#   Reset path → after a PR is detected, counter resets

bash .agents/scripts/tests/test-stale-recovery-escalation.sh
bash .agents/scripts/tests/test-parent-task-guard.sh  # regression
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh  # regression
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/dispatch-dedup-helper.sh
```

## Acceptance Criteria

- [ ] Stale-recovery counter implemented as structured comment marker
- [ ] After `STALE_RECOVERY_THRESHOLD` consecutive recoveries, `needs-maintainer-review` is applied AND a human-readable explanation comment is posted
- [ ] Counter resets when a PR is detected for the issue (to avoid false-escalation on slow-but-progressing tasks)
- [ ] New test file `tests/test-stale-recovery-escalation.sh` with at least 5 assertions
- [ ] Existing tests still pass

## Relevant Files

- `.agents/scripts/dispatch-dedup-helper.sh` — search for "stale assignment recovery" or `STALE_RECOVERED`
- `.agents/scripts/tests/test-parent-task-guard.sh` — test stub pattern reference
- `.agents/configs/dispatch-stale-recovery.conf` (NEW)

## Dependencies

- **Blocked by:** none
- **Related:** t1986 (parent-task guard, merged), t2007 (cost circuit breaker, sibling Tier B/C), t2009 (cross-runner doc — should mention this escalation path)

## Estimate

~3h.

## Out of scope

- Cross-runner counter consistency (the comment-based design handles this naturally; no extra coordination needed)
- Auto-recovery from `needs-maintainer-review` (humans handle this — that's the point of the escalation)
- Tunable per-tier thresholds (one threshold for all tiers in v1; can be per-tier in a follow-up)

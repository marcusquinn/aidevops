<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2040: fix(pulse): label-invariant reconciler with backfill

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code:interactive
- **Created by:** ai-interactive (Marcus approved combined t2040+t2041 execution)
- **Parent task:** none
- **Conversation context:** User audit of open aidevops issues surfaced polluted state — 9 issues with dual `status:available`+`status:queued` labels (pre-t2033 write-without-remove bug) and 5 with multiple `tier:*` labels (issue-sync enrich concatenation bug). PRs #18519 (t2033) and #18441 (t1997) fixed the sources going forward but neither does retroactive cleanup. User directive: "fix deterministic issues systemically as we go, otherwise we're just moving them to a logic that will go stale" — meaning: enforce the invariant colocated with the existing reconciler, not as a separate routine.

## What

Extend `normalize_active_issue_assignments()` in `.agents/scripts/pulse-issue-reconcile.sh` with a new pass `_normalize_label_invariants()` that enforces two invariants on every open issue in every pulse-enabled repo, every pulse cycle:

1. **At most one `status:*` core label.** On violation, keep the highest-precedence label and remove siblings via `set_issue_status`.
2. **At most one `tier:*` label.** On violation, keep highest rank (`tier:reasoning` > `tier:standard` > `tier:simple`).

Also addresses three cycle/race risks discovered during race analysis:

3. Fix `issue-sync-helper.sh` enrich path (line 689-704) to strip existing `tier:*` from `labels` before appending brief tier — prevents flap cycle with the reconciler.
4. Migrate `_mark_issue_done()` (line 232-242) to use `set_issue_status "done"` — removes the last non-atomic two-call add+remove pattern in the codebase, closing the transient multi-label window.
5. Document and enforce `STATUS_LABEL_PRECEDENCE` in `shared-constants.sh` with `done` as terminal (wins if present) — guards against data loss in any future non-atomic sequence.

Invariant enforcement runs in the existing pre-run normalization stage wired at `pulse-dispatch-engine.sh:776` — no new scheduler, no new cron, no new routine.

## Why

Two systemic fixes (PR #18519, PR #18441) landed in the last 4 hours. They prevent new pollution but leave 14 already-polluted issues in degraded state until each is touched. The reconciler approach self-heals on the next pulse cycle, then remains a permanent invariant check — cheap, deterministic, colocated with siblings (`_normalize_reassign_self`, `_normalize_unassign_stale`, `_normalize_clear_status_labels`).

Without this task: the polluted issues sit in ambiguous state, the LLM priority rules ("status:available or no status → dispatch" in `pulse-sweep.md`) become undefined, cascade escalation breaks when tier is ambiguous, and any new bug writing bad labels goes undetected until the next audit.

## Tier

### Tier checklist

- [ ] 2 or fewer files to modify? **No** — 3 files (`pulse-issue-reconcile.sh`, `issue-sync-helper.sh`, `shared-constants.sh`) plus tests
- [x] Complete code blocks for every edit? Most — but precedence logic needs judgment
- [ ] No judgment or design decisions? **No** — precedence order, where to insert the pass
- [x] No error handling or fallback logic to design? Reconciler uses existing best-effort patterns
- [ ] Estimate 1h or less? **No** — ~2-3h including tests
- [ ] 4 or fewer acceptance criteria? **No** — 8 below

**Selected tier:** `tier:standard`

**Tier rationale:** 3 files edited, 2 test files added, precedence design, integration with existing reconciler pattern. Narrative brief with file references is sufficient; no novel architecture. Standard.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/shared-constants.sh:~971` — add `STATUS_LABEL_PRECEDENCE` array next to `ISSUE_STATUS_LABELS`
- `EDIT: .agents/scripts/pulse-issue-reconcile.sh` — add `_normalize_label_invariants()` helper, wire into `normalize_active_issue_assignments()` coordinator, add counters to summary log line
- `EDIT: .agents/scripts/issue-sync-helper.sh:699-704` — strip existing `tier:*` from `labels` before appending brief tier
- `EDIT: .agents/scripts/issue-sync-helper.sh:232-242` — migrate `_mark_issue_done()` to `set_issue_status "done"`
- `NEW: .agents/scripts/tests/test-normalize-label-invariants.sh` — fixture-based assertions for the reconciler pass
- `NEW: .agents/scripts/tests/test-issue-sync-tier-dedupe.sh` — enrich path test
- `NEW: .agents/scripts/tests/test-mark-issue-done-atomic.sh` — confirm migration

### Implementation Steps

1. **Add `STATUS_LABEL_PRECEDENCE`** to `shared-constants.sh` below `ISSUE_STATUS_LABELS`:

    ```bash
    # t2040: precedence order for label-invariant reconciliation. First match wins.
    # `done` is terminal — always preserved if present (guards against transient
    # multi-label windows from any future non-atomic sequence).
    STATUS_LABEL_PRECEDENCE=("done" "in-review" "in-progress" "queued" "claimed" "available" "blocked")
    ```

2. **Add `_normalize_label_invariants()`** to `pulse-issue-reconcile.sh` modeled on `_normalize_clear_status_labels()`. For each open issue in each pulse-enabled repo:
   - Fetch labels via `gh issue view --json labels`
   - Count `status:*` labels; if >1, pick survivor by `STATUS_LABEL_PRECEDENCE` order, call `set_issue_status "$survivor"`, increment `status_fixed` counter
   - Count `tier:*` labels; if >1, pick survivor by rank `reasoning > standard > simple`, call `gh issue edit --remove-label "$loser"` for each loser, increment `tier_fixed` counter
   - Count issues with `origin:interactive` label AND no `tier:*` AND no `auto-dispatch` AND no `status:*` AND created >30min ago — increment `triage_missing` counter (flag only, no auto-fix)

3. **Wire into coordinator** — extend `normalize_active_issue_assignments()` to call `_normalize_label_invariants` as a third pass after `_normalize_unassign_stale`.

4. **Summary log line** — add `status_fixed=N tier_fixed=N triage_missing=N` to the existing reconciler summary.

5. **Fix `issue-sync-helper.sh` enrich path** (line 699-704):

    ```bash
    # BEFORE appending brief tier, strip any existing tier:* from labels
    if [[ -n "$tier_label" ]]; then
        labels=$(echo "$labels" | tr ',' '\n' | grep -v '^tier:' | paste -sd, -)
        if [[ -n "$labels" ]]; then
            labels="${labels},${tier_label}"
        else
            labels="$tier_label"
        fi
    fi
    ```

6. **Migrate `_mark_issue_done()`** to atomic call:

    ```bash
    _mark_issue_done() {
        local repo="$1" num="$2"
        set_issue_status "$num" "$repo" "done"
    }
    ```

7. **Tests:** fixture-based shell scripts that stub `gh` and verify the reconciler/enrich logic. Model on existing `test-pulse-wrapper-characterization.sh` for the stubbing pattern.

### Verification

```bash
# Lint
shellcheck .agents/scripts/shared-constants.sh .agents/scripts/pulse-issue-reconcile.sh .agents/scripts/issue-sync-helper.sh

# Unit tests
.agents/scripts/tests/test-normalize-label-invariants.sh
.agents/scripts/tests/test-issue-sync-tier-dedupe.sh
.agents/scripts/tests/test-mark-issue-done-atomic.sh

# Regression: existing characterization tests still pass
.agents/scripts/tests/test-pulse-wrapper-characterization.sh

# Live verification: check polluted issues get cleaned up on next pulse cycle
gh issue view 18484 --repo marcusquinn/aidevops --json labels --jq '[.labels[].name | select(startswith("status:") or startswith("tier:"))]'
# Expected: at most 1 status:*, at most 1 tier:*
```

## Acceptance Criteria

- [ ] `STATUS_LABEL_PRECEDENCE` added to `shared-constants.sh` with `done` as terminal
- [ ] `_normalize_label_invariants()` added to `pulse-issue-reconcile.sh`, wired into coordinator
- [ ] `issue-sync-helper.sh` enrich path dedupes `tier:*` before appending brief tier
- [ ] `_mark_issue_done()` migrated to atomic `set_issue_status "done"`
- [ ] `test-normalize-label-invariants.sh` passes (dual-status reduction, triple-tier reduction, single-label no-op, triage-missing count-only)
- [ ] `test-issue-sync-tier-dedupe.sh` passes (TODO `#tier:simple` + brief `tier:reasoning` → labels = `tier:reasoning`)
- [ ] `test-mark-issue-done-atomic.sh` passes (single `gh issue edit` call)
- [ ] `test-pulse-wrapper-characterization.sh` regression suite passes unchanged
- [ ] `shellcheck` clean on all edited files
- [ ] Reconciler summary log line includes `status_fixed` / `tier_fixed` / `triage_missing` counters
- [ ] Live: current 9 dual-status + 5 multi-tier polluted issues normalize on next pulse cycle

## Context & Decisions

- **Why reconciler not GH Action for status:** status labels change via every dispatch cycle; an Action firing on every label event is noisier than a single pass inside the pulse cycle. Tier labels already have the GH Action (`dedup-tier-labels.yml`); reconciler is the backfill path for issues not touched since that Action merged.
- **Why `done` is terminal in precedence:** guards against data loss during the `_mark_issue_done` non-atomic window (fixed in this task, but precedence must still be correct for any future code that isn't atomic).
- **Why triage-missing is flag-only:** tier assignment and brief creation need human judgment; the reconciler counts and logs, leaving action to the maintainer.
- **Drive-by scope:** `_mark_issue_done` migration and issue-sync tier dedupe are included because they're prerequisites for the reconciler to be race-safe, not because they're independently worth a task. Scoping them out would create a known-broken interaction.

## Relevant Files

- `.agents/scripts/pulse-issue-reconcile.sh:1-528` — existing reconciler, pattern to follow
- `.agents/scripts/shared-constants.sh:971` — `ISSUE_STATUS_LABELS` array
- `.agents/scripts/shared-constants.sh:1041-1088` — `set_issue_status` helper (t2033)
- `.agents/scripts/issue-sync-helper.sh:118-152` — `_is_protected_label` / `_is_tag_derived_label` (namespace rules)
- `.agents/scripts/issue-sync-helper.sh:689-704` — enrich path concatenation bug
- `.agents/scripts/issue-sync-helper.sh:232-242` — `_mark_issue_done` non-atomic sequence
- `.github/workflows/dedup-tier-labels.yml` — existing tier GH Action (same rank order, idempotent with reconciler)
- `.agents/scripts/pulse-dispatch-engine.sh:776` — existing reconciler wiring point
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh` — stubbing pattern for tests

## Dependencies

- **Blocked by:** none (PR #18519 and #18441 already merged)
- **Blocks:** t2041 (LLM sweep reads `triage_missing` counter from this task's output)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read reconciler + set_issue_status | 15m | pattern discovery |
| Implementation | 90m | 3 file edits + precedence array |
| Tests | 60m | 3 test files with gh stub fixtures |
| Verification | 15m | shellcheck, regression suite, live check |
| **Total** | **~3h** | |

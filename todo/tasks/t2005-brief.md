<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2005: Phase 12 — split `normalize_active_issue_assignments()` (189 lines)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** t1962 Phase 12 follow-up (plan §6, candidate #7)
- **Function location:** `.agents/scripts/pulse-issue-reconcile.sh:38` (extracted in Phase 5, t1973 / #18381)

## What

Split `normalize_active_issue_assignments()` into per-state-transition helpers. The function reconciles issue assignment state across runners — detecting and fixing inconsistencies between assignees, status labels, and dispatch comments.

Target structure:
1. **`_normalize_unassign_stale()`** — detect stale assignees (worker dead, no progress) and unassign
2. **`_normalize_clear_status_labels()`** — strip `status:queued` / `status:in-progress` from issues with no active worker
3. **`_normalize_reassign_self()`** — re-attach self when this runner has the active claim
4. Parent becomes a thin coordinator that calls each in sequence. <40 lines.

## Why

- 189 lines, ties with `_is_task_committed_to_main` for mid-tier complexity.
- This is one of the functions implicated in the GH#18356 dispatch race that motivated t1986. Splitting per-concern makes future bugs easier to localize.
- Per-state-transition helpers can be unit-tested independently with stubbed `gh` calls.

## Tier

`tier:standard`.

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-issue-reconcile.sh:38-226` — `normalize_active_issue_assignments()` body
- **VERIFY:** no direct test exercises this function; the live pulse + characterization test cover it indirectly. Add a stubbed test if extraction makes one feasible.

### Recommended split

Same pattern as t2004 — identify natural seams (likely at `# Step N:` comments or `case` branches), extract each into a private helper, parent becomes coordinator.

### Verification

```bash
bash -n .agents/scripts/pulse-issue-reconcile.sh
.agents/scripts/pulse-wrapper.sh --self-check
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-issue-reconcile.sh
# Sandbox dry-run
# Post-merge: monitor live pulse for "normalize_active_issue_assignments" log lines, verify behaviour matches pre-split
```

## Acceptance Criteria

- [ ] `normalize_active_issue_assignments()` reduced to under 40 lines
- [ ] At least 3 new helper functions extracted
- [ ] All existing pulse tests pass
- [ ] `--self-check` clean
- [ ] `shellcheck` no new findings
- [ ] **Stretch:** add a stub-based test in `tests/test-issue-reconcile.sh` that exercises one of the new helpers via `gh` stubbing (mirrors `test-parent-task-guard.sh` pattern from t1986)

## Relevant Files

- `.agents/scripts/pulse-issue-reconcile.sh:38`
- `.agents/scripts/tests/test-parent-task-guard.sh` — stub-based test pattern reference

## Dependencies

- **Related:** t1986 (parent-task guard, just merged) — same dispatch-hardening family

## Estimate

~1.5h, or 2.5h with the stretch test.

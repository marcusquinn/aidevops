# t2396: fix(pulse-issue-reconcile): extend `_normalize_reassign_self` to cover `status:available` worker issues with feedback-routed markers

## Session origin

- Date: 2026-04-19
- Context: Diagnostic session. After ci-feedback-routing sets an issue back to `status:available` for re-dispatch, the next pulse cycle dispatches it but the `_normalize_reassign_self` safety net doesn't re-assign the runner — so if the dispatch assignment races with PR-creation time, the PR's maintainer-gate sees an empty assignee list.
- Sibling tasks: t2394 (CLAIM_VOID), t2395 (maintainer-gate exemption), t2397 (HARD STOP age-out), t2398 (hot-deploy).

## What

`pulse-issue-reconcile.sh` `_normalize_reassign_self` currently only self-assigns issues with `status:queued` OR `status:in-progress`. Extend the filter to ALSO cover `status:available` issues that meet ALL of:
1. Have `origin:worker` label
2. Have a feedback-routed marker in the issue body (`<!-- ci-feedback:PR* -->`, `<!-- conflict-feedback:PR* -->`, `<!-- review-followup:PR* -->`) OR a `source:*-feedback` label
3. Have NO current assignees (honour existing user assignment)

These are issues that were previously dispatched, had a PR that failed/conflicted/got-review-feedback, and have been routed back to `available` for re-dispatch. The original runner's assignee got cleared during the route-back transition; normalisation should restore it so the next dispatch cycle preserves it through PR creation.

## Why

**Root cause confirmed in production 2026-04-19.** Issue #19924 timeline shows:

1. Pulse scanner creates (16:47): `status:available`, `assignees=[]`, `source:review-scanner`, `source:ci-feedback`
2. Worker dispatched (16:04:45): `_launch_worker` sets `status:queued` + self-assigns `alex-solovyev`
3. Worker fast-fails (16:05:57): `pulse-cleanup.sh` unassigns + sets `status:available`
4. **Gap**: `_normalize_reassign_self` skips the issue because `status:available` is not in its filter
5. Next dispatch cycle: issue is available for re-dispatch (correct), but arrives at PR-creation without a pending runner assignment — race with ci-feedback routing order can leave `assignees=[]` at gate-check time

`_normalize_reassign_self` exists specifically to restore assignment continuity through pulse-internal state transitions. The filter at `status:queued|in-progress` assumes only actively-dispatched issues need restoration, but feedback-routed-back issues ALSO need continuity because they retain dispatch context (the routed feedback in their body).

Current filter (see `pulse-issue-reconcile.sh` `_normalize_reassign_self`):

```bash
# Only covers status:queued, status:in-progress
```

## How

### Files to modify

- **EDIT**: `.agents/scripts/pulse-issue-reconcile.sh` — `_normalize_reassign_self` function.
  - Add `status:available` to the status filter.
  - Add guard: only self-assign when ALL of:
    - `origin:worker` label present
    - Either (a) `source:*-feedback` label present, OR (b) issue body contains one of the feedback-routed markers (grep for `<!-- ci-feedback:PR`, `<!-- conflict-feedback:PR`, `<!-- review-followup:PR`).
    - `assignees` array is empty.
  - Keep existing status:queued / status:in-progress logic unchanged.

### Reference pattern

- Model on the existing `_normalize_reassign_self` body (same function). The `origin:worker` + feedback-marker gate is parallel to the existing `status:queued + no-assignee` gate — just a parallel condition leading into the same self-assign gh-api call.
- Feedback-routed-marker extraction: `pulse-merge-feedback.sh:186, 299` show the marker format (`<!-- ci-feedback:PR{N} -->`, `<!-- conflict-feedback:PR{N} -->`). Use `grep -q '<!-- ci-feedback:PR\|<!-- conflict-feedback:PR\|<!-- review-followup:PR'`.

### Constants

Add to `shared-constants.sh` if not already present:

```bash
FEEDBACK_ROUTED_LABELS=(
  "source:ci-feedback"
  "source:conflict-feedback"
  "source:review-feedback"
  "source:review-scanner"
)
FEEDBACK_ROUTED_MARKERS=(
  "<!-- ci-feedback:PR"
  "<!-- conflict-feedback:PR"
  "<!-- review-followup:PR"
)
```

## Acceptance criteria

1. An issue with `status:available`, `origin:worker`, `source:ci-feedback`, and no assignees is self-assigned by the next pulse normalisation cycle.
2. An issue with `status:available`, `origin:worker`, and a `<!-- ci-feedback:PR... -->` marker in its body is self-assigned by the next pulse normalisation cycle, even without a `source:*` label.
3. An issue with `status:available` and NO `origin:worker` label is NOT self-assigned (unchanged behaviour — respects user control over non-worker issues).
4. An issue with `status:available` and existing user assignees is NOT touched (unchanged behaviour).
5. Dedup guard: a fresh scanner-created issue (no feedback markers yet, no prior dispatch) is NOT self-assigned here — it goes through the normal dispatch path which handles assignment at that layer.
6. Regression: existing `status:queued|status:in-progress` self-assign behaviour preserved.
7. `shellcheck` passes.

## Verification

```bash
# Regression test
.agents/scripts/tests/test-reassign-self-normalization.sh  # extend existing test file

# Spot-check: simulate the feedback-routed case
.agents/scripts/pulse-issue-reconcile.sh --dry-run --issue 19924 --repo marcusquinn/aidevops

# Logs after deploy: look for "reassign-self" log lines targeting status:available issues
tail -f ~/.aidevops/logs/pulse.log | grep -i "reassign-self"
```

## Context

- Interacts with t2394 (CLAIM_VOID): once CLAIM_VOID lands, feedback-routed re-dispatch becomes reliable, which makes the normalisation path more relevant.
- Interacts with t2395 (maintainer-gate exemption): even with this fix, maintainer-gate exemption is still needed for the race window where the PR's gate runs before normalisation fires.
- Priority: MEDIUM — a belt-and-braces fix that reduces the race window but doesn't eliminate it. t2395 is the true fix for the gate failure.

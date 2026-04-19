<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2372 — fix(pulse): tighten `_normalize_unassign_stale` 1h cutoff to 10min for faster orphan-worker recovery

**Tier:** standard
**Origin:** interactive (2026-04-19 session)
**Type:** bugfix — pulse pipeline throughput

## What

Lower the `updatedAt` candidate-eligibility filter in `_normalize_unassign_stale` (`.agents/scripts/pulse-issue-reconcile.sh`) from `now - 3600` (1 hour) to `now - 600` (10 minutes), and make the value tunable via the `STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS` environment variable.

## Why

The proactive stale-worker recovery sweep currently has an outer time filter that excludes any issue updated in the last hour from consideration. A worker that dies between dispatch and PR creation leaves the issue assigned + `status:queued`, but the issue's `updatedAt` is the dispatch-comment timestamp — so the sweep ignores it for ~60 minutes after dispatch.

The reactive `_is_stale_assignment` check (in `dispatch-dedup-stale.sh`) uses a 600s threshold, but only fires when the pulse attempts to RE-DISPATCH the same issue (Layer 6 dedup). If the queue is large and the issue is not the next dispatch candidate, the reactive path may not run for hours.

Result observed in the 2026-04-19 session: 7 orphan workers across `marcusquinn/aidevops` (#19750, #19756, #19740, #19699, #19743, #19741, #19739, #19746) had to be manually unassigned to unblock dispatch. Pulse log shows zero `Stale assignment reset:` entries for the entire log file (~3MB), confirming the proactive sweep almost never fires due to the 1h filter.

The 1h was inherited from a pre-extraction copy in `pulse-wrapper.sh` (Phase 5 extraction `1c780b437` was a "pure move"). It has never been tuned and predates the multi-layer inner safeguards (`_normalize_stale_should_skip_reset`) that already protect live workers.

## How

**Edit** `.agents/scripts/pulse-issue-reconcile.sh:265-312` (`_normalize_unassign_stale`):

1. Replace the hard-coded `3600` in the `cutoff` calculation:

   ```bash
   # OLD
   stale_issues=$(printf '%s' "$stale_json" | jq -r --arg cutoff "$((now_epoch - 3600))" '
   ```

   with:

   ```bash
   # NEW
   local _stale_threshold="${STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS:-600}"
   [[ "$_stale_threshold" =~ ^[0-9]+$ ]] || _stale_threshold=600
   stale_issues=$(printf '%s' "$stale_json" | jq -r --arg cutoff "$((now_epoch - _stale_threshold))" '
   ```

2. Update the function docstring (`pulse-issue-reconcile.sh:243-264`) to document the new threshold semantics, the env var override, and the rationale for the 10-min default (matches `STALE_ASSIGNMENT_THRESHOLD_SECONDS=600` in `dispatch-dedup-stale.sh`).

3. Add a one-line entry log when the sweep BEGINS scanning (currently only logs on action, so silent runs are invisible):

   ```bash
   # New: at function entry, after total_reset=0
   echo "[pulse-wrapper] Stale assignment scan: threshold=${_stale_threshold}s" >>"$LOGFILE"
   ```

   Keep the existing per-action and summary log lines.

**Test** `.agents/scripts/tests/test-issue-reconcile.sh` — add a test case that:

1. Stages a fake issue JSON with `updatedAt` 15 min ago and `status:queued`
2. Confirms the new threshold (600) puts it in the candidate set
3. Stages a second fake issue with `updatedAt` 5 min ago
4. Confirms it is NOT in the candidate set (still recent)
5. Tests the env var override (set `STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS=1800` and confirm 15-min issue is now excluded)

## Acceptance criteria

- [ ] `_normalize_unassign_stale` outer filter uses 600s default, env-var configurable
- [ ] Function docstring updated with rationale and env-var name
- [ ] One-line entry log added (`Stale assignment scan: threshold=Xs`)
- [ ] Inner safeguards (`_normalize_stale_should_skip_reset`) unchanged — pgrep, dispatch PID liveness, worker log mtime all preserved
- [ ] Test covers default threshold, custom threshold via env var, and the boundary case
- [ ] `shellcheck` clean on the edited file
- [ ] PR title format: `t2372: fix(pulse): tighten _normalize_unassign_stale 1h cutoff to 10min`
- [ ] PR body uses `Resolves #NNN` linking to the GH issue

## Context / safety

- The 10-min default matches `STALE_ASSIGNMENT_THRESHOLD_SECONDS=600` in `dispatch-dedup-stale.sh` — proactive and reactive paths now use the same window.
- Inner safeguards (`_normalize_stale_should_skip_reset`) already protect live workers via three independent checks (local pgrep, dispatch-comment PID liveness with cross-runner guard, worker log mtime <600s).
- Lowering the OUTER filter to 600s expands the candidate set 6x; the inner guards still gate the actual reset action.
- The age-floor guard from t2153 lives in `_is_stale_assignment` (reactive path), not in `_normalize_unassign_stale`. This change does NOT need a separate age-floor — `updatedAt` is naturally bounded by issue creation time (an issue can't have `updatedAt < createdAt`).
- `WORKER_MAX_RUNTIME` (cross-runner guard) is independent and unchanged.
- This is a one-knob tightening with documented rationale and full safeguards. No behavioural surprise.

## Files

- EDIT: `.agents/scripts/pulse-issue-reconcile.sh` (lines ~265-312)
- EDIT: `.agents/scripts/tests/test-issue-reconcile.sh` (add test cases)

## Verification

```bash
# Test
.agents/scripts/tests/test-issue-reconcile.sh

# Shellcheck
shellcheck .agents/scripts/pulse-issue-reconcile.sh

# Local sanity: confirm grep finds new threshold
grep -n 'STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS' .agents/scripts/pulse-issue-reconcile.sh
```

After merge, verify in pulse log within 1-2 cycles:

```bash
grep '\[pulse-wrapper\] Stale assignment scan:' ~/.aidevops/logs/pulse-wrapper.log | tail -5
```

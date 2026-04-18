<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2218: claim-task-id.sh self-assigns even when auto-dispatch (missing t2157 carve-out in _auto_assign_issue)

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code interactive session
- **Created by:** ai-interactive (Marcus Quinn driving)
- **Conversation context:** During the t2191 follow-up planning session (PR #19701), three issues created via `claim-task-id.sh` (#19692/#19693/#19694) all had `auto-dispatch` labels and ALL got self-assigned to `marcusquinn`. The combo `(origin:interactive + assignee)` then blocked pulse dispatch per GH#18352/t1996, requiring manual `gh issue edit --remove-assignee` on all three before workers could pick them up. The carve-out at line 792 of `claim-task-id.sh` exists for `_interactive_session_auto_claim_new_task` (skips `status:in-review` when `auto-dispatch` is in TASK_LABELS) but `_auto_assign_issue` at line 698 has no equivalent and runs unconditionally before the carve-out path is reached.

## What

Add a t2157-style `auto-dispatch` carve-out to `_auto_assign_issue()` in `.agents/scripts/claim-task-id.sh` so that when an interactive session creates a task explicitly intended for worker dispatch, the issue is created without self-assignment — matching the existing behavior of `issue-sync-helper.sh::_push_auto_assign_interactive` (line 572). This eliminates the `(origin:interactive + assignee)` dispatch-block combo for `auto-dispatch`-tagged issues created via the `claim-task-id.sh` path.

## Why

Today the user has to manually `gh issue edit --remove-assignee` after every `claim-task-id.sh` invocation that creates an `auto-dispatch` issue, or the pulse will never dispatch a worker — a 24h `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` safety net (t2148) is the only autonomous recovery, which is unacceptable latency. The fix is symmetric: `issue-sync-helper.sh` already does the right thing; `claim-task-id.sh` should match.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** (1 file: `claim-task-id.sh`)
- [x] **Every target file under 500 lines?** (claim-task-id.sh is 1447 lines — DOES NOT QUALIFY by raw size, but the change is exact-block-localized to lines 698-716, so the size disqualifier is mitigated by the verbatim oldString/newString below)
- [x] **Exact `oldString`/`newString` for every edit?** (yes, see Implementation Steps)
- [x] **No judgment or design decisions?** (mirror existing pattern at issue-sync-helper.sh:572 verbatim)
- [x] **No error handling or fallback logic to design?** (existing function already handles all paths)
- [x] **No cross-package or cross-module changes?** (single function in one script)
- [x] **Estimate 1h or less?** (~10 minutes)
- [x] **4 or fewer acceptance criteria?** (3)

**Selected tier:** `tier:simple`

**Tier rationale:** Single-function edit in one script with verbatim copy-pasteable replacement block. The 1447-line file size is mitigated because the change is bounded to a 19-line function with explicit insertion point (line 707). Pattern is taken verbatim from `issue-sync-helper.sh:571-575`.

## PR Conventions

Leaf (non-parent) issue. PR body MUST use `Resolves #19718`.

## Files to Modify

- `EDIT: .agents/scripts/claim-task-id.sh` — add the carve-out at the top of `_auto_assign_issue()` (line 698)

## Implementation Steps

### Step 1: Add the auto-dispatch carve-out to `_auto_assign_issue()`

Mirror the t2157 pattern from `.agents/scripts/issue-sync-helper.sh:571-575` exactly. The check goes at the **top** of the function, before any other work, so the early-return is cheap.

**oldString** (lines 695-706 of `.agents/scripts/claim-task-id.sh`):

```bash
# Auto-assign a newly created issue to the current GitHub user.
# Prevents duplicate dispatch when multiple machines/pulses are running.
# Non-blocking — assignment failure doesn't fail issue creation.
_auto_assign_issue() {
	local issue_num="$1"
	local repo_path="$2"

	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$current_user" ]]; then
		return 0
	fi
```

**newString:**

```bash
# Auto-assign a newly created issue to the current GitHub user.
# Prevents duplicate dispatch when multiple machines/pulses are running.
# Non-blocking — assignment failure doesn't fail issue creation.
#
# t2218: skip self-assign when the task carries auto-dispatch labels.
# Mirrors the t2157 carve-out in issue-sync-helper.sh::_push_auto_assign_interactive.
# When an interactive session creates a task intended for worker dispatch
# (auto-dispatch label present), self-assigning the pusher creates the
# (origin:interactive + assignee) combo that GH#18352/t1996 dedup-blocks
# the pulse from dispatching a worker. Skip the assignment so the pulse
# can dispatch immediately; the issue retains origin:interactive for
# provenance.
_auto_assign_issue() {
	local issue_num="$1"
	local repo_path="$2"

	# t2218: skip when auto-dispatch tag present — issue is worker-owned.
	# TASK_LABELS is the module-level variable set by --labels parsing.
	if [[ ",${TASK_LABELS:-}," == *",auto-dispatch,"* ]]; then
		log_info "Skipping auto-assign for #${issue_num} — auto-dispatch entry is worker-owned (t2218)"
		return 0
	fi

	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
	if [[ -z "$current_user" ]]; then
		return 0
	fi
```

### Step 2: Add a regression test

Model on `.agents/scripts/tests/test-auto-dispatch-no-assign.sh` (the existing t2157 regression test for `issue-sync-helper.sh`). Either extend that test with an additional case covering `claim-task-id.sh` directly, or create a new test `.agents/scripts/tests/test-claim-task-id-auto-dispatch-no-assign.sh` that:

1. Sources `claim-task-id.sh` (or invokes it as a subprocess)
2. Sets `TASK_LABELS="bug,auto-dispatch,framework"`
3. Stubs `gh` to record arguments
4. Calls `_auto_assign_issue 99999 /tmp`
5. Asserts that `gh issue edit ... --add-assignee` was NOT invoked

Either approach is acceptable. Adding a case to the existing test is preferred for cohesion with t2157.

## Verification

```bash
# 1. shellcheck clean (no new violations)
shellcheck .agents/scripts/claim-task-id.sh

# 2. The carve-out fires when expected
TASK_LABELS="bug,auto-dispatch,framework" bash -c '
  source .agents/scripts/claim-task-id.sh
  # Stub gh to fail loudly if called with --add-assignee
  gh() { if [[ " $* " == *" --add-assignee "* ]]; then echo "FAIL: assigned despite auto-dispatch"; exit 1; fi; return 0; }
  export -f gh
  _auto_assign_issue 99999 "$(pwd)"
  echo "PASS: skipped self-assign for auto-dispatch task"
'

# 3. The carve-out does NOT fire for non-auto-dispatch tasks
TASK_LABELS="bug,framework" bash -c '
  source .agents/scripts/claim-task-id.sh
  gh() { if [[ " $* " == *" --add-assignee "* ]]; then echo "PASS: would self-assign as expected"; exit 0; fi; return 0; }
  export -f gh
  _auto_assign_issue 99999 "$(pwd)" || true
'

# 4. Regression test passes
bash .agents/scripts/tests/test-auto-dispatch-no-assign.sh  # (or new test file)
```

## Acceptance Criteria

- [ ] `_auto_assign_issue()` returns early without calling `gh issue edit ... --add-assignee` when `TASK_LABELS` contains `auto-dispatch`
- [ ] Regression test exists and passes (added to existing `test-auto-dispatch-no-assign.sh` OR new `test-claim-task-id-auto-dispatch-no-assign.sh`)
- [ ] `shellcheck .agents/scripts/claim-task-id.sh` clean (no new SC violations)

## Context & Decisions

- **Why TASK_LABELS check, not the issue's actual labels?** TASK_LABELS is the in-memory module-level variable set by `--labels` parsing OR auto-extracted from `#hashtags` in the title (see lines 244-250). Checking the in-memory state matches the t2157 pattern and avoids a redundant `gh issue view` round-trip. The issue's labels at this point are exactly what we just passed to `gh issue create`, so the two are equivalent.
- **Why not also gate on session origin?** `_interactive_session_auto_claim_new_task` does check session origin (line 783-786), but `_auto_assign_issue` does not. Adding an origin check here would be over-restrictive: workers also benefit from skipping self-assign on `auto-dispatch` tasks (the worker should claim via the dispatch flow, not via creation-time self-assign). t2157 in `issue-sync-helper.sh` does NOT gate on origin either (line 569-575).
- **Coordination with `_interactive_session_auto_claim_new_task`?** That function also has the `auto-dispatch` check (line 792). With both gates in place, an `auto-dispatch` issue created via `claim-task-id.sh` ends up with: assignment skipped (t2218), `status:in-review` skipped (t2132 Fix B), `origin:interactive` label applied for provenance (line 1077), `auto-dispatch` label applied. The pulse can then dispatch a worker on the next cycle.

## Relevant files

- **Edit:** `.agents/scripts/claim-task-id.sh` — `_auto_assign_issue()` at lines 695-716
- **Pattern source:** `.agents/scripts/issue-sync-helper.sh` — `_push_auto_assign_interactive()` at lines 562-592 (t2157 carve-out at 571-575)
- **Test (extend or model):** `.agents/scripts/tests/test-auto-dispatch-no-assign.sh`
- **Related:** GH#18352/t1996 dispatch-dedup combined-signal rule; t2057 (`_interactive_session_auto_claim_new_task` introduction); t2132 Fix B (label-based carve-out for `_interactive_session_auto_claim_new_task`)

## Dependencies

None. Self-contained fix.

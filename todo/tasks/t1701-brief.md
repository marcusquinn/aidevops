<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1701: Make dispatch dedup guard atomic — single function wrapping dedup+assign+launch

**Session origin:** User reported duplicate workers on GH#12141 — both pulses skipped `check_dispatch_dedup` entirely
**Task ID:** t1701 | **Issue:** GH#12436
**Status:** ready | **Estimate:** ~3h

## What

Create a `dispatch_with_dedup()` function in `pulse-wrapper.sh` that atomically wraps all 7 dedup layers + issue assignment + worker launch into a single call. Update `pulse.md` to instruct the LLM to call this single function instead of the current 3-step sequence (check_dispatch_dedup → gh issue edit → headless-runtime-helper.sh run).

## Why

GH#12141 root cause: both `marcusquinn` (v3.5.87 opus) and `alex-solovyev` (v3.5.86 sonnet) pulse sessions dispatched workers for the same issue within 2 minutes. **Neither pulse ran `check_dispatch_dedup` at all** — zero `DISPATCH_CLAIM` comments exist on the issue, and no "Dispatch skipped" comment was posted.

The current architecture has a fundamental weakness: the dedup guard is LLM-instructed. The pulse.md tells the LLM to run a bash code block containing `check_dispatch_dedup`, but the LLM can (and did) skip it. `# MANDATORY` in a prompt is a suggestion, not an enforcement.

Timeline of GH#12141:
- 00:11 — recovery: relabelled `status:available`, unassigned
- 00:36 — `marcusquinn` opus pulse posts "Dispatching worker" (no prior claim)
- 00:38 — `alex-solovyev` sonnet pulse posts "Dispatching worker" (no prior claim)
- 00:41 — `alex-solovyev` creates PR #12397
- 00:42 — `alex-solovyev` posts implementation complete

Both pulses went straight to dispatch without running the dedup guard. Layer 5 (dispatch comment check) would have caught the second dispatch if it had been called — the first "Dispatching worker" comment was already 2 minutes old.

## How

### 1. New `dispatch_with_dedup()` function in `pulse-wrapper.sh`

```bash
dispatch_with_dedup() {
    local issue_number="$1"
    local repo_slug="$2"
    local title="$3"
    local issue_title="$4"
    local self_login="$5"
    local repo_path="$6"
    local prompt="$7"
    local session_key="${8:-issue-${issue_number}}"

    # All 7 dedup layers — cannot be skipped
    if check_dispatch_dedup "$issue_number" "$repo_slug" "$title" "$issue_title" "$self_login"; then
        echo "[dispatch_with_dedup] Dedup guard blocked #${issue_number} in ${repo_slug}" >>"$LOGFILE"
        return 1
    fi

    # Assign issue
    gh issue edit "$issue_number" --repo "$repo_slug" \
        --add-assignee "$self_login" --add-label "status:queued" 2>/dev/null || true

    # Launch worker
    "$HEADLESS_RUNTIME_HELPER" run \
        --role worker \
        --session-key "$session_key" \
        --dir "$repo_path" \
        --title "$title" \
        --prompt "$prompt" &
    sleep 2

    # Record in dispatch ledger
    local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
    if [[ -x "$ledger_helper" ]]; then
        "$ledger_helper" record --issue "$issue_number" --repo "$repo_slug" \
            --pid "$!" --title "$title" 2>/dev/null || true
    fi

    return 0
}
```

### 2. Update `pulse.md` dispatch instructions

Replace the current 3-step code block:
```bash
# Current (skippable):
if check_dispatch_dedup ...; then continue; fi
gh issue edit ... --add-assignee ...
headless-runtime-helper.sh run ... &
```

With single call:
```bash
# New (atomic):
source ~/.aidevops/agents/scripts/pulse-wrapper.sh
dispatch_with_dedup NUMBER SLUG "Issue #NUMBER: TITLE" "TASK_ID: TITLE" "$RUNNER_USER" PATH "/full-loop ..."
```

### 3. Keep `check_dispatch_dedup` exported

The function remains available for other callers (tests, manual checks, `/runners`). `dispatch_with_dedup` is the recommended dispatch path; `check_dispatch_dedup` is the standalone guard for non-standard flows.

### Files to modify

- `.agents/scripts/pulse-wrapper.sh` — add `dispatch_with_dedup()` function (~40 lines)
- `.agents/scripts/commands/pulse.md` — update Step 4 dispatch instructions to use single function call
- `.agents/scripts/tests/test-pulse-wrapper-worker-detection.sh` — add test for `dispatch_with_dedup`

## Acceptance Criteria

- [ ] `dispatch_with_dedup` function exists in `pulse-wrapper.sh` and runs all 7 dedup layers before launching
- [ ] `pulse.md` Step 4 uses `dispatch_with_dedup` as the single dispatch call
- [ ] LLM cannot dispatch a worker without the dedup guard running — there is no code path that separates them
- [ ] `check_dispatch_dedup` remains available as a standalone function for non-pulse callers
- [ ] Claim comments persist as audit trail (losing claims are NOT deleted — confirmed by `a544b2055`)
- [ ] Dispatch ledger recording happens inside the atomic function
- [ ] ShellCheck clean, Bash 3.2 compatible
- [ ] Existing tests pass, new test covers `dispatch_with_dedup`

## Context

- Root cause incident: GH#12141 (duplicate dispatch, no claim comments)
- Prior claim lock implementation: t1686 / GH#6877 / `dispatch-claim-helper.sh`
- Claim deletion removal: `a544b2055` (PR #12359) — losing claims now persist
- Plain text claims: `6a8208c1a` (PR #12285) — visible in rendered view
- Dedup layers: `pulse-wrapper.sh:4113` (`check_dispatch_dedup`)
- Claim protocol: `dispatch-claim-helper.sh` (optimistic locking via GitHub comments)
- Dispatch comment check: `dispatch-dedup-helper.sh:555` (`has_dispatch_comment`)
- Pulse dispatch instructions: `pulse.md:65-89`

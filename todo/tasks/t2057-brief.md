<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2057: Phase 2 — wire interactive-session-helper into worktree-helper, claim-task-id, approval-helper

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code (interactive)
- **Parent task:** t2055 / GH#18738
- **Depends on:** t2056 / GH#18739 (Phase 1 — imports `interactive-session-helper.sh`)
- **Conversation context:** Phase 2 of the interactive-session auto-claim feature. Flips the mandatory bit — once this merges, every sanctioned interactive path (creating a worktree for an issue, claiming a new task, approving a contributor issue) automatically exercises the helper. This is the code-level safety net for paths the Phase 1 AI-guidance rule might miss.

## What

Wire the Phase 1 `interactive-session-helper.sh` into three existing subsystems so the claim/release behaviour applies automatically on the framework's sanctioned paths, independent of whether the agent noticed the conversation intent:

1. **`worktree-helper.sh`** — on `add` with a branch whose name already encodes an issue number (existing parse in `_worktree_handle_loop_mode` at `~:495`), call `claim` after the worktree is created.
2. **`claim-task-id.sh`** — after `_auto_assign_issue` on the interactive new-task path, transition the issue to `status:in-review` via the helper so new tasks land in the same state interactive sessions use.
3. **`approval-helper.sh`** — in `_post_issue_approval_updates`, after the existing `needs-maintainer-review` → `auto-dispatch` churn, idempotently clear `status:in-review` if present (no new user commands, no new prompts — pure additive behaviour on the existing `sudo aidevops approve issue` path).

Plus one extension to the dispatch-dedup multi-operator test to assert the new case: an interactive session engaged on an existing `origin:worker` issue blocks pulse dispatch via `status:in-review` + self-assignment.

## Why

Phase 1 ships the primary enforcement layer via the `prompts/build.txt` rule, which makes every future interactive session responsible for calling `claim`/`release` from conversation intent. That's the belt. Phase 2 is the braces — when the sanctioned paths exercise the helper automatically, the mechanism still works if:

- The agent misses the conversation signal
- The session is pre-compacted and the rule drops from context
- A runtime without full access to the build.txt rule layer (e.g., a restricted subagent) still creates worktrees

Three subsystems cover every reasonable path to "interactive session is now working on this issue":

- **Opening a worktree with `wt switch -c`** — the most common entry point; almost every interactive task starts here. `worktree-helper.sh` already parses `gh<N>-` / `t<N>-` from the branch name, so the wiring is one call after the existing branch-add.
- **Claiming a new task** — `claim-task-id.sh` already self-assigns the new issue; adding a status transition to `in-review` is the same pattern two lines later.
- **Crypto approval of a contributor issue** — this is the only case where an interactive session transitions an `origin:worker` issue into ready-for-dispatch state. Without this wiring, a maintainer who reviewed a contributor issue interactively (applying `status:in-review` via Phase 1's AI rule or worktree wiring) would leave the label set after approval, and the pulse would still skip dispatch. The idempotent clear fixes that.

## Tier

### Tier checklist

- [ ] **2 or fewer files to modify?** No — 4 files across three subsystems. tier:simple disqualified.
- [x] **Complete code blocks for every edit?** Yes — specified below.
- [x] **No judgment or design decisions?** Yes — Phase 1 settled the contract; this phase is pure wiring.
- [x] **No error handling or fallback logic to design?** Yes — helper handles its own failure modes; callers use `|| true`.
- [x] **Estimate 1h or less?** ~40 minutes.
- [x] **4 or fewer acceptance criteria?** Yes — 5 (one over, justified by three subsystems).

**Selected tier:** `tier:standard` — three-subsystem wiring with clear pattern references. Could be `tier:simple` once Phase 1 has merged, but standard is safer given the hot-path edits.

## How (Approach)

### Files to modify

- **EDIT:** `.agents/scripts/worktree-helper.sh` — post-add claim hook
- **EDIT:** `.agents/scripts/claim-task-id.sh` — post-`_auto_assign_issue` status transition
- **EDIT:** `.agents/scripts/approval-helper.sh` — idempotent `in-review` → `available` in `_post_issue_approval_updates`
- **EDIT:** `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` — +1 assertion

### `worktree-helper.sh` change

After the existing branch parse at `~:495` that extracts `_wt_issue_num`, and AFTER the `git worktree add` has succeeded, call the helper. The existing code flow:

```bash
# Existing:
local _wt_issue_num=""
_wt_issue_num=$(printf '%s' "$_wt_task_desc" | grep -oE '#[0-9]+|issue[/ ]*([0-9]+)' | grep -oE '[0-9]+' | head -1) || _wt_issue_num=""
```

needs to be enriched so the same parse runs on the *branch name* (not just the task description) when the caller is the `add` subcommand. Specifically: after `git worktree add` succeeds, if the branch name matches `(gh|t)([0-9]+)` and the session is interactive, call:

```bash
if [[ "$(detect_session_origin)" == "interactive" ]]; then
    local _wh_issue_num=""
    if [[ "$branch_name" =~ /(gh|t)([0-9]+)[-_] ]]; then
        _wh_issue_num="${BASH_REMATCH[2]}"
    fi
    if [[ -n "$_wh_issue_num" ]]; then
        local _wh_slug
        _wh_slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null | \
            sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
        if [[ -n "$_wh_slug" ]]; then
            "${SCRIPT_DIR}/interactive-session-helper.sh" claim \
                "$_wh_issue_num" "$_wh_slug" --worktree "$worktree_path" \
                >/dev/null 2>&1 || true
        fi
    fi
fi
```

Guard: only when the helper exists on disk (graceful if Phase 1 isn't deployed).

### `claim-task-id.sh` change

Around `:807` where `_auto_assign_issue "$issue_num" "$repo_path"` is called, add immediately after (same-level indentation):

```bash
# t2057: transition interactive new-task to status:in-review so the pulse
# dispatch-dedup guard honours the claim. Idempotent and non-blocking.
if [[ "$(detect_session_origin)" == "interactive" ]]; then
    local _ct_slug
    _ct_slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null | \
        sed 's|.*github\.com[:/]||;s|\.git$||' || echo "")
    if [[ -n "$_ct_slug" && -x "${SCRIPT_DIR}/interactive-session-helper.sh" ]]; then
        "${SCRIPT_DIR}/interactive-session-helper.sh" claim \
            "$issue_num" "$_ct_slug" >/dev/null 2>&1 || true
    fi
fi
```

Guard: only when helper is executable; falls through silently if not.

### `approval-helper.sh` change

In `_post_issue_approval_updates` around `:354` (after the `gh issue lock` call), add:

```bash
# t2057: idempotent release of status:in-review — if the maintainer was
# interactively reviewing this contributor issue before signing the
# cryptographic approval, the in-review label must clear so the pulse
# can dispatch. No-op when not set.
local _ah_labels
_ah_labels=$(gh issue view "$target_number" --repo "$slug" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
if [[ "$_ah_labels" == *"status:in-review"* ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/shared-constants.sh"
    set_issue_status "$target_number" "$slug" "available" \
        >/dev/null 2>&1 || true
    _print_info "Released status:in-review (interactive review transitioned to available)"
fi
```

Guard: label check is the idempotency gate; the `source` is already established pattern in the helper.

### Test extension

`.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` currently covers 7 assertions for the combined-signal dedup rule. Add an 8th:

```bash
# Assertion 8 (t2057): interactive session on existing origin:worker issue
# carrying status:in-review + non-self assignee must block dispatch.
write_fixture_issue '[{"name":"origin:worker"},{"name":"status:in-review"},{"name":"tier:standard"}]' \
    '[{"login":"other-maintainer"}]'
assert_blocks "origin:worker + in-review + non-self assignee blocks dispatch"
```

Pattern lifted from existing assertions in the same file.

### Verification

```bash
# 1. Shellcheck clean on all modified files
shellcheck .agents/scripts/worktree-helper.sh \
           .agents/scripts/claim-task-id.sh \
           .agents/scripts/approval-helper.sh

# 2. Phase 1 test harness still passes (no regression)
bash .agents/scripts/tests/test-interactive-session-claim.sh

# 3. Extended dedup test passes (including new assertion 8)
bash .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh

# 4. Manual smoke: worktree auto-claim
wt switch -c bugfix/gh18738-phase2-smoke
gh issue view 18738 --repo marcusquinn/aidevops --json labels,assignees
# Expected: status:in-review + self-assignment

# 5. Manual smoke: claim-task-id auto-transition
claim-task-id.sh --title "test: phase 2 claim smoke" --description "ignore"
# Verify the created issue has status:in-review label

# 6. Manual smoke: approval-helper release (requires sudo + contributor issue)
# sudo aidevops approve issue <contributor-issue-number>
# Verify status:in-review removed idempotently
```

## Acceptance Criteria

- [ ] `worktree-helper.sh` calls `interactive-session-helper.sh claim` on `add` when the branch name matches `/(gh|t)([0-9]+)[-_]` and session is interactive
  ```yaml
  verify:
    method: codebase
    pattern: "interactive-session-helper.sh.*claim"
    path: ".agents/scripts/worktree-helper.sh"
  ```
- [ ] `claim-task-id.sh` calls the helper after `_auto_assign_issue` when origin is interactive
  ```yaml
  verify:
    method: codebase
    pattern: "interactive-session-helper.sh.*claim"
    path: ".agents/scripts/claim-task-id.sh"
  ```
- [ ] `approval-helper.sh` `_post_issue_approval_updates` idempotently clears `status:in-review` when present
  ```yaml
  verify:
    method: codebase
    pattern: "status:in-review.*set_issue_status.*available"
    path: ".agents/scripts/approval-helper.sh"
  ```
- [ ] `test-dispatch-dedup-multi-operator.sh` has a new assertion covering the `origin:worker + in-review + non-self assignee` case
  ```yaml
  verify:
    method: codebase
    pattern: "interactive session on existing origin:worker"
    path: ".agents/scripts/tests/test-dispatch-dedup-multi-operator.sh"
  ```
- [ ] All four modified files are shellcheck clean
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/worktree-helper.sh .agents/scripts/claim-task-id.sh .agents/scripts/approval-helper.sh .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh"
  ```

## Context & Decisions

- **Why guard each call site with `[[ -x "$helper" ]]` instead of depending on Phase 1?** So the Phase 2 PR can merge independently of the Phase 1 PR order. If by some accident Phase 2 lands first, the wiring falls through silently and nothing breaks. Phase 1 brief already covers the helper deployment.
- **Why three separate call sites and not one shared hook?** Each subsystem has its own idiom. `worktree-helper.sh` thinks in terms of branch names; `claim-task-id.sh` thinks in terms of task IDs; `approval-helper.sh` thinks in terms of cryptographic payloads. A shared hook would abstract away the three distinct argument shapes for no real benefit — three explicit call sites are easier to audit.
- **Why `approval-helper.sh` only clears `in-review` if present (not always)?** Idempotency. The maintainer may approve an issue they never touched interactively (they read the body and signed from a terminal). In that case `in-review` was never set and the clear is a no-op. The label check is the gate.
- **Non-goals:**
  - Changing the Phase 1 helper (bugs there are Phase 1's responsibility — fix forward)
  - Adding pre-edit-check.sh fallback (dropped in design review)
  - Adding branch-name regex beyond what `worktree-helper.sh` already parses
  - Touching dispatch-dedup-helper.sh (already handles in-review)

## Relevant Files

- `.agents/scripts/interactive-session-helper.sh` — Phase 1 helper this phase calls (imported via full path + guard)
- `.agents/scripts/worktree-helper.sh:495` — existing branch-name parse pattern to mirror
- `.agents/scripts/claim-task-id.sh:807` — insertion point after `_auto_assign_issue`
- `.agents/scripts/approval-helper.sh:354` — insertion point after `gh issue lock` in `_post_issue_approval_updates`
- `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` — pattern source for new assertion

## Dependencies

- **Blocked by:** Phase 1 (t2056 / GH#18739) — this phase calls the helper Phase 1 ships
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| worktree-helper.sh edit | 10m | Branch parse + post-add claim call |
| claim-task-id.sh edit | 5m | Two-line addition after `_auto_assign_issue` |
| approval-helper.sh edit | 5m | Idempotent label clear in existing helper |
| Test extension | 10m | +1 assertion, reuse existing fixture helpers |
| Verification + smoke | 5m | shellcheck, test runs, manual wt/claim |
| Commit + PR | 5m | Conventional commit, PR body |
| **Total** | **~40m** | |

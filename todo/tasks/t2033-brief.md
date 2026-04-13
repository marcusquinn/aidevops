<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2033: fix(pulse): enforce mutually-exclusive status labels via helper

## Origin

- **Created:** 2026-04-13
- **Session:** claude-code:t2033
- **Created by:** marcusquinn (ai-interactive)
- **Parent task:** none
- **Conversation context:** While diagnosing why issues #18444, #18454, #18455 kept stale-recovering without t2008 escalation firing, audit revealed the issues had BOTH `status:available` AND `status:queued` applied simultaneously. Traced to `_dispatch_launch_worker` adding `status:queued` without removing sibling status labels. Broader audit shows 8+ label-transition sites constructing ad-hoc remove lists — the status state machine isn't enforced anywhere.

## What

Introduce a shared `set_issue_status` helper in `.agents/scripts/shared-constants.sh` that transitions an issue to a new `status:*` label atomically, removing all sibling status labels in the same `gh issue edit` call. Replace every ad-hoc `--add-label status:* / --remove-label status:*` construction in the `.agents/scripts` tree with calls to the helper. After this change, no issue should ever carry two `status:*` labels simultaneously, and stale-recovery tick counters (t2008) fire reliably because the state machine is consistent.

## Why

aidevops aims to be a continually accurate state and auditing machine. Label inconsistency breaks this contract in three concrete ways:

1. **Dispatch dedup becomes unreliable** — `dispatch-dedup-helper.sh` checks for "active status labels" but when both `status:available` and `status:queued` coexist, different code paths disagree on whether the issue is active.
2. **t2008 stale-recovery escalation doesn't fire** — the tick-counter logic detected that issues #18444/#18454/#18455 have burned multiple reasoning-tier cycles but only recorded `tick:1` each, because intermediate cycles didn't go through a clean `available → queued → in-progress → stale-recover` transition.
3. **Audit trails lie** — `gh issue list --label "status:available"` returns issues that are actively assigned. Health dashboards and cross-runner coordination guards can't trust label queries.

Root cause: each call site constructs its own `--add-label/--remove-label` list and several forget to remove one or more siblings. This is a systemic state-machine problem, not a single bug fix. A centralized helper is the only durable solution.

## Tier

### Tier checklist (verify before assigning)

- [ ] 2 or fewer files to modify? — NO, 8+ files touched
- [x] Complete code blocks for every edit? — yes, but scope is wide
- [ ] No judgment or design decisions? — NO, helper API design + deciding which call sites to migrate vs. leave as fallbacks
- [x] No error handling or fallback logic to design? — yes, helper wraps existing gh edit pattern
- [ ] Estimate 1h or less? — NO, ~2h
- [ ] 4 or fewer acceptance criteria? — NO, 7 criteria

Any unchecked → not `tier:simple`.

**Selected tier:** `tier:standard`

**Tier rationale:** Narrative brief with explicit file paths, pattern references, and a complete helper skeleton. Touches 8 scripts across the pulse code path — scope is wide but each edit is mechanical substitution. Sonnet can handle this with the references below; no architectural reasoning required.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/shared-constants.sh` — add `set_issue_status()` and `ISSUE_STATUS_LABELS` constant
- `EDIT: .agents/scripts/pulse-dispatch-core.sh:1062` — `_dispatch_launch_worker` — use `set_issue_status queued` (THE PRIMARY BUG)
- `EDIT: .agents/scripts/pulse-dispatch-core.sh:1446` — check this call site too (already removes available/queued)
- `EDIT: .agents/scripts/dispatch-dedup-helper.sh:599-602` — stale-recovery escalation path — `set_issue_status blocked` or `needs-maintainer-review` (leave the `needs-maintainer-review` add as-is, but use helper for status removal)
- `EDIT: .agents/scripts/dispatch-dedup-helper.sh:642-644` — stale-recovery normal path — `set_issue_status available`
- `EDIT: .agents/scripts/pulse-issue-reconcile.sh:123-133` — `_normalize_clear_status_labels` — use helper
- `EDIT: .agents/scripts/pulse-issue-reconcile.sh:486-488,499-501,520-522` — stale-done reset paths — use helper
- `EDIT: .agents/scripts/pulse-cleanup.sh:576-584` — launch recovery — use helper
- `EDIT: .agents/scripts/pulse-dep-graph.sh:267-273` — unblock path — use helper
- `EDIT: .agents/scripts/pulse-quality-debt.sh:116` — quality-debt reset — use helper
- `EDIT: .agents/scripts/full-loop-helper.sh:795-808` — `_label_issue_in_review` — use helper
- `EDIT: .agents/scripts/worker-watchdog.sh:926-936` — kill recovery — already does the right thing (removes all 5 active statuses + adds destination) — migrate to helper for consistency
- `NEW: .agents/scripts/tests/test-status-label-state-machine.sh` — unit test that stubs `gh issue edit` and asserts the helper always emits the complete set of remove flags
- `EDIT: .agents/scripts/tests/run-all-tests.sh` (if present) — register new test
- `EDIT: .agents/configs/dispatch-stale-recovery.conf` — already documents threshold=2 per the user's spec; no change needed

### Implementation Steps

1. **Add `set_issue_status` helper to `shared-constants.sh`**. Must be sourceable from all call sites (use `# shellcheck source=/dev/null`). Pattern:

```bash
# Canonical ordered list of mutually-exclusive status:* labels.
# When transitioning, all siblings of the target must be removed atomically.
ISSUE_STATUS_LABELS=(available queued claimed in-progress in-review done blocked)

#######################################
# Transition an issue to a status:* label atomically.
#
# Removes every sibling status:* label in a single `gh issue edit` call,
# then adds the target. This is the ONLY sanctioned way to change an issue's
# status label — ad-hoc --add-label/--remove-label calls must go through
# this helper so the status state machine is enforced centrally.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — new status: one of available|queued|claimed|in-progress|in-review|done|blocked
#        OR empty string to clear all status labels without adding one
#   $@ — additional gh issue edit flags (e.g., --add-assignee, --remove-assignee,
#        --add-label "other-label") passed through verbatim.
#
# Returns:
#   0 on gh success, non-zero on gh failure. Errors are suppressed (2>/dev/null)
#   to match existing call-site conventions — callers should not depend on
#   specific exit codes.
#######################################
set_issue_status() {
    local issue_num="$1"
    local repo_slug="$2"
    local new_status="$3"
    shift 3

    # Validate target status (empty is allowed = clear only)
    if [[ -n "$new_status" ]]; then
        local _valid=0
        local _status
        for _status in "${ISSUE_STATUS_LABELS[@]}"; do
            [[ "$_status" == "$new_status" ]] && { _valid=1; break; }
        done
        if [[ "$_valid" -eq 0 ]]; then
            printf 'set_issue_status: invalid status "%s" (valid: %s)\n' \
                "$new_status" "${ISSUE_STATUS_LABELS[*]}" >&2
            return 2
        fi
    fi

    # Build flag list: remove all status:* labels, add target if non-empty.
    # `gh issue edit --remove-label` is idempotent — absent labels produce
    # a non-fatal 404 that gh swallows. This lets us unconditionally remove
    # all siblings without first querying the issue's current labels.
    local -a _flags=()
    local _label
    for _label in "${ISSUE_STATUS_LABELS[@]}"; do
        if [[ "$_label" == "$new_status" ]]; then
            _flags+=(--add-label "status:${_label}")
        else
            _flags+=(--remove-label "status:${_label}")
        fi
    done

    # Pass through any extra flags the caller wants to apply in the same edit
    # (e.g., --add-assignee, --remove-assignee, --add-label "other-non-status-label")
    _flags+=("$@")

    gh issue edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null
}
```

2. **Verify `gh issue edit --remove-label` is idempotent on absent labels**. Test manually first: create a scratch issue, run `gh issue edit N --repo OWNER/REPO --remove-label "nonexistent-label"` and confirm exit 0. If gh returns non-zero on absent labels, the helper must pre-fetch current labels and only remove present ones — add a `gh issue view ... --json labels` lookup and filter.

3. **Migrate `pulse-dispatch-core.sh:_dispatch_launch_worker`** — the primary bug. Replace line 1062 construction with a single `set_issue_status` call that passes through the assignee swap flags:

```bash
# BEFORE (line 1062)
local -a _edit_flags=(--add-assignee "$self_login" --add-label "status:queued" --add-label "origin:worker")
# ... then build remove-assignee flags and call gh issue edit once

# AFTER
local -a _extra=(--add-assignee "$self_login" --add-label "origin:worker")
local _prev_login
while IFS= read -r _prev_login; do
    [[ -n "$_prev_login" && "$_prev_login" != "$self_login" ]] && _extra+=(--remove-assignee "$_prev_login")
done < <(printf '%s' "$issue_meta_json" | jq -r '.assignees[].login' 2>/dev/null)

set_issue_status "$issue_number" "$repo_slug" "queued" "${_extra[@]}" || true
```

4. **Migrate `dispatch-dedup-helper.sh:_recover_stale_assignment`** (lines 599-602 and 642-644). Both paths become `set_issue_status`:

```bash
# Escalation path (line 598-602)
set_issue_status "$issue_number" "$repo_slug" "" --add-label "needs-maintainer-review" || true

# Normal recovery path (line 642-644)
set_issue_status "$issue_number" "$repo_slug" "available" || true
```

5. **Migrate remaining call sites** mechanically. Each site's target status is obvious from context:

| File | Line(s) | Target status | Extra flags |
|------|---------|---------------|-------------|
| `pulse-issue-reconcile.sh` | 128-131 | `available` | `--remove-assignee "$runner_user"` |
| `pulse-issue-reconcile.sh` | 486-488, 499-501, 520-522 | `available` | none |
| `pulse-cleanup.sh` | 580-583 | `available` | `--remove-assignee "$self_login"` |
| `pulse-cleanup.sh` | 577-578 (blocked branch) | `""` (clear only) | `--remove-assignee "$self_login"` |
| `pulse-dep-graph.sh` | 268-269 | `available` | none |
| `pulse-quality-debt.sh` | 116 | `available` | none |
| `full-loop-helper.sh` | 802-805 | `in-review` | none |
| `worker-watchdog.sh` | 928-934 | `$destination_status` (variable) | none |

6. **Add `source` line to every migrated file** if not already sourcing shared-constants.sh. Use `SCRIPT_DIR` / `BASH_SOURCE` resolution consistent with neighboring helpers in the same file. Example:

```bash
# Near the top of each file, alongside existing sources
# shellcheck source=/dev/null
source "${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")}/shared-constants.sh"
```

Many files already source `shared-constants.sh` — check before adding.

7. **Write `test-status-label-state-machine.sh`** — stub `gh` in PATH, invoke the helper with each valid status, assert the captured `gh issue edit` command line contains exactly one `--add-label status:<target>` and `N-1` `--remove-label status:<other>` flags. Model on `.agents/scripts/tests/test-stale-recovery-escalation.sh` which already stubs `gh`.

Test cases:
- `set_issue_status 1 owner/repo queued` → 1 add, 6 removes, 0 extras
- `set_issue_status 1 owner/repo available --remove-assignee alex` → 1 add, 6 removes, `--remove-assignee alex`
- `set_issue_status 1 owner/repo "" --add-label needs-maintainer-review` → 0 status adds, 7 status removes, `--add-label needs-maintainer-review`
- `set_issue_status 1 owner/repo invalid` → exit 2, no gh call
- `set_issue_status 1 owner/repo in-progress` → passes through `--remove-label status:claimed` (enforces t1996 normalization)

### Verification

```bash
# 1. Helper exists and passes its unit test
shellcheck .agents/scripts/shared-constants.sh
bash .agents/scripts/tests/test-status-label-state-machine.sh

# 2. No ad-hoc --add-label "status:*" outside the helper (whitelist tests/ and the helper itself)
rg --multiline '(add|remove)-label "status:' .agents/scripts \
  | grep -v 'shared-constants.sh' \
  | grep -v 'tests/' \
  | grep -v 'set_issue_status' \
  && { echo "Ad-hoc status label calls remain"; exit 1; } \
  || echo "All status label transitions go through helper"

# 3. Existing test suites still pass
bash .agents/scripts/tests/test-stale-recovery-escalation.sh
bash .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh
bash .agents/scripts/tests/test-issue-reconcile.sh

# 4. Shellcheck all touched files
for f in .agents/scripts/pulse-dispatch-core.sh \
         .agents/scripts/dispatch-dedup-helper.sh \
         .agents/scripts/pulse-issue-reconcile.sh \
         .agents/scripts/pulse-cleanup.sh \
         .agents/scripts/pulse-dep-graph.sh \
         .agents/scripts/pulse-quality-debt.sh \
         .agents/scripts/full-loop-helper.sh \
         .agents/scripts/worker-watchdog.sh \
         .agents/scripts/shared-constants.sh; do
    shellcheck "$f" || exit 1
done
```

## Acceptance Criteria

- [ ] `set_issue_status` helper exists in `shared-constants.sh` with the signature above and rejects invalid status values with exit 2
  ```yaml
  verify:
    method: codebase
    pattern: "^set_issue_status\\(\\)"
    path: ".agents/scripts/shared-constants.sh"
  ```
- [ ] `ISSUE_STATUS_LABELS` array contains exactly: available, queued, claimed, in-progress, in-review, done, blocked
  ```yaml
  verify:
    method: codebase
    pattern: "ISSUE_STATUS_LABELS=\\(available queued claimed in-progress in-review done blocked\\)"
    path: ".agents/scripts/shared-constants.sh"
  ```
- [ ] `_dispatch_launch_worker` no longer constructs ad-hoc `--add-label "status:queued"` — it calls `set_issue_status`
  ```yaml
  verify:
    method: codebase
    pattern: "--add-label \"status:queued\""
    path: ".agents/scripts/pulse-dispatch-core.sh"
    expect: absent
  ```
- [ ] No file in `.agents/scripts` (excluding `shared-constants.sh`, `tests/`, and documentation) constructs `--add-label "status:*"` or `--remove-label "status:*"` directly
  ```yaml
  verify:
    method: bash
    run: "! rg -l '(add|remove)-label \"status:' .agents/scripts --glob '!shared-constants.sh' --glob '!tests/**' --glob '!*.md'"
  ```
- [ ] New test `test-status-label-state-machine.sh` exists and passes with 5+ assertions covering valid/invalid statuses, the empty-status clear path, and extra-flag pass-through
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-status-label-state-machine.sh"
  ```
- [ ] All pre-existing label/dispatch tests still pass
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-stale-recovery-escalation.sh && bash .agents/scripts/tests/test-dispatch-dedup-multi-operator.sh && bash .agents/scripts/tests/test-issue-reconcile.sh"
  ```
- [ ] Shellcheck clean on all touched files
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/shared-constants.sh .agents/scripts/pulse-dispatch-core.sh .agents/scripts/dispatch-dedup-helper.sh .agents/scripts/pulse-issue-reconcile.sh .agents/scripts/pulse-cleanup.sh .agents/scripts/pulse-dep-graph.sh .agents/scripts/pulse-quality-debt.sh .agents/scripts/full-loop-helper.sh .agents/scripts/worker-watchdog.sh"
  ```

## Context & Decisions

- **Why a helper instead of fixing `_dispatch_launch_worker` alone:** The user explicitly asked for systemic correctness ("aidevops aims to be a continually accurate state and auditing machine"). Fixing one call site leaves the pattern fragile — the next added call site will repeat the bug. A helper centralises enforcement.
- **Why `gh issue edit --remove-label` idempotency matters:** If absent labels cause non-zero exit, the helper would need to pre-fetch current labels. Step 2 of Implementation Steps explicitly verifies this first.
- **Why include `status:claimed`:** t1996 normalization treats `status:claimed` as an active lifecycle label alongside `queued/in-progress/in-review`. It belongs in the mutually-exclusive set.
- **Why NOT touch `status:blocked` co-existence:** Semantically `status:blocked` is mutually exclusive with active lifecycle states — an issue waiting on a dependency should not simultaneously have a worker assigned. Including `blocked` in the helper enforces this.
- **Things ruled out:**
  - Replacing labels via `gh api ... -X PUT labels` (atomic but clobbers non-status labels like `tier:*`, `origin:*`, `auto-dispatch`, `bug` — too risky).
  - Deferring the worker-watchdog migration (already correct, but migrating for consistency prevents future drift).
- **Prior art:** t1996 combined-signal dedup, t2008 stale-recovery escalation — both sit ON TOP of the status label state machine. This task fixes the state machine so those higher-level guards work reliably.

## Relevant Files

- `.agents/scripts/shared-constants.sh` — canonical constants + helper location
- `.agents/scripts/pulse-dispatch-core.sh:1062` — primary bug site
- `.agents/scripts/dispatch-dedup-helper.sh:540-628` — stale-recovery logic depends on clean label state
- `.agents/scripts/worker-watchdog.sh:926-936` — reference pattern (already removes all siblings correctly)
- `.agents/scripts/tests/test-stale-recovery-escalation.sh` — `gh` stub pattern to model the new test on
- `.agents/configs/dispatch-stale-recovery.conf` — threshold config (no change, already `STALE_RECOVERY_THRESHOLD=2`)

## Dependencies

- **Blocked by:** none
- **Blocks:** t2008 reliable firing on future stuck issues; any future task that adds a new status label must extend `ISSUE_STATUS_LABELS`
- **External:** none — all mocks are local

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | confirm gh idempotency, read each call site context |
| Helper + test | 30m | shared-constants.sh + test harness |
| Call-site migration | 45m | 8 files, mechanical substitution |
| Testing | 20m | run all touched test suites, shellcheck |
| PR + review | 10m | commit-and-pr helper |
| **Total** | **~2h** | |

# t2890: align /full-loop interactive gate with pulse dispatch primitives

## Session origin

Surfaced during interactive `/full-loop #20518` triage (2026-04-26). Issue #20518 is a held `parent-task` + `no-auto-dispatch` decomposition tracker. The pulse correctly refuses to dispatch on it (`dispatch-dedup-helper.sh is-assigned` returns `PARENT_TASK_BLOCKED (label=parent-task)`). The interactive `/full-loop` entry point does NOT call the same primitive — only intelligence-layer reading of the issue body caught the mismatch. If `_check_linked_issue_gate`'s missing-assignee check (Check 2) had passed (e.g., issue self-assigned, or carrying `quality-debt`), `/full-loop` would have proceeded onto a non-dispatchable parent-task.

## What

Extend `_check_linked_issue_gate` in `.agents/scripts/full-loop-helper.sh` to call `dispatch-dedup-helper.sh is-assigned` after the existing NMR + assignee checks, and translate the canonical `PARENT_TASK_BLOCKED` and `NO_AUTO_DISPATCH_BLOCKED` stdout signals into hard blocks with mentoring error messages. Fail-open on tooling errors (matches the existing pattern at lines 197-200).

## Why

Gate enforcement asymmetry between pulse and interactive entry points. The pulse has rich dispatch gates (parent-task, no-auto-dispatch, cost-budget, hydration window, ownership) consolidated in `dispatch-dedup-helper.sh::is-assigned`. The interactive `/full-loop` path was added later (GH#17810) with a narrow purpose (NMR + assignee) and never reconciled with the canonical primitive. Result: a maintainer typing `/full-loop` on a parent-task or no-auto-dispatch issue is only saved by coincidental side checks, not structural correctness.

This single change brings the interactive path into structural parity with the pulse for the two unambiguous hard-block signals. Cost-budget, hydration window, and ownership-by-other are intentionally out of scope here (they need nuanced interactive UX — e.g., the user typing `/full-loop` on their own claimed issue must still proceed) and tracked as separate followups.

## How

### Files Scope

- `.agents/scripts/full-loop-helper.sh`

### Files to modify

- **EDIT** `.agents/scripts/full-loop-helper.sh:174-238` (`_check_linked_issue_gate`) — add Check 3 calling `dispatch-dedup-helper.sh is-assigned` and translating `PARENT_TASK_BLOCKED` / `NO_AUTO_DISPATCH_BLOCKED` signals.

### Reference pattern

- Pulse callsite: `.agents/scripts/pulse-dispatch-dedup-layers.sh:243` — canonical invocation of `is-assigned`.
- Existing fail-open pattern in the same function: `full-loop-helper.sh:197-200` (gh api fetch failure → skip gate).
- Gate primitive: `.agents/scripts/dispatch-dedup-helper.sh:638-720` (`_is_assigned_check_parent_task`, `_is_assigned_check_no_auto_dispatch`).

### Implementation steps

1. After Check 2 (assignee) at line 228, before the `blocked` evaluation at line 230, add:
   - Locate `dispatch-dedup-helper.sh` via `${SCRIPT_DIR}/dispatch-dedup-helper.sh`
   - Skip if not executable (fail-open)
   - Call `is-assigned <issue_num> <repo> <self-login>` capturing stdout
   - Match `*PARENT_TASK_BLOCKED*` and `*NO_AUTO_DISPATCH_BLOCKED*` substrings on stdout
   - Append a clear, mentoring reason to `$reasons` and set `blocked=true`
2. Update the function header comment to mention the new gate.

### Verification

- `shellcheck ~/Git/aidevops.t2890-full-loop-gate-parity/.agents/scripts/full-loop-helper.sh` clean.
- Manual smoke (without actually starting work): confirm `_check_linked_issue_gate` extracted into a callable form returns 1 (blocked) for #20518 and emits both reasons in the message stream.

## Acceptance

1. `_check_linked_issue_gate` calls `dispatch-dedup-helper.sh is-assigned` after Check 2.
2. `PARENT_TASK_BLOCKED` substring on dedup stdout produces `blocked=true` with a mentoring reason naming the label.
3. `NO_AUTO_DISPATCH_BLOCKED` substring on dedup stdout produces `blocked=true` with a mentoring reason naming the label.
4. Dedup helper missing or returning empty stdout is fail-open (no block, no error).
5. shellcheck clean.

## Followups (out of scope here)

- Cost-budget signal interactive UX (warn vs block).
- Ownership-by-other (`is-assigned` reports another assignee with active claim) — needs UX for the legitimate "I'm continuing my own claim" case.
- Rename `is-assigned` to `is-eligible-for-dispatch` (semantic clarity, broader refactor).
- Recalibrate Trigger 4 wording on #20518 (separate issue — calibration, not gating).

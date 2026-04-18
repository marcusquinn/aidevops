<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2242: full-loop-helper — auto-swap Resolves to For when linked issue has parent-task label

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19760
**Tier:** standard (auto-dispatch)

## What

When `full-loop-helper.sh commit-and-pr --issue NNN` runs against a `parent-task`-labeled issue, `_build_pr_body()` at `full-loop-helper.sh:714` hardcodes `Resolves #${issue_number}`. The `parent-task-keyword-guard` (run at `:915-930` with `--strict`) then correctly refuses PR creation with exit 2 per t2046. User is forced to compose the PR body manually and call `gh_create_pr` directly.

## Why

Every parent-task PR will hit this — helper and guard are in permanent conflict on this issue class. Cost per hit: ~3 extra tool calls per parent-task PR (signature-helper footer, manual body compose, `gh_create_pr`). PR #19758 (t2228 retrospective) hit it; every future retrospective, roadmap tracker, or decomposition-parent PR will hit it.

The fix preserves the existing `--allow-parent-close` override for the rare final-phase-closes-parent case.

## How

### Files to modify

- **EDIT:** `.agents/scripts/full-loop-helper.sh:697-718` (`_build_pr_body()` — add parent-task detection + conditional keyword emit)
- **NEW:** `.agents/scripts/tests/test-full-loop-parent-task.sh`

### Reference pattern

Model `_issue_has_parent_task_label()` on `.agents/scripts/parent-task-keyword-guard.sh:76` (`_is_parent_task` — queries `gh issue view --json labels` + jq filter for `parent-task` or `meta` label). Copy-paste-able — only function name and scope differ.

### Implementation outline

1. Add helper `_issue_has_parent_task_label()` near the top of `full-loop-helper.sh` (mirroring the keyword-guard function). Use a module-level associative array cache keyed by `issue_number:repo` to avoid duplicate `gh` calls across `_build_pr_body` and the keyword-guard invocation later in the same `commit-and-pr` flow.
2. In `_build_pr_body()`, before the existing `Resolves` line (714), determine keyword:
   - If `--allow-parent-close` was passed → `Resolves` (closes parent, final-phase semantics preserved)
   - Else if issue has `parent-task` label → `For`
   - Else → `Resolves` (back-compat)
3. The existing `parent-task-keyword-guard --strict` call at :925 continues to run unchanged — it will now pass because the body uses `For` when appropriate.
4. Regression test stubs `gh issue view --json labels` to return both cases.

### Verification

- `shellcheck .agents/scripts/full-loop-helper.sh` clean
- `bash .agents/scripts/tests/test-full-loop-parent-task.sh` green
- End-to-end smoke: create a test issue with `parent-task` label, run `full-loop-helper.sh commit-and-pr --issue <N>` with a trivial commit. Confirm (a) PR body contains `For #<N>`, (b) keyword-guard does not block.

## Acceptance Criteria

- [ ] `_build_pr_body` emits `For #NNN` when linked issue has `parent-task` label
- [ ] `_build_pr_body` emits `Resolves #NNN` for non-parent issues (back-compat)
- [ ] `--allow-parent-close` override forces `Resolves` even on parent-task (final-phase case)
- [ ] Regression test covers all three cases
- [ ] ShellCheck clean

## Context

Discovered during PR #19758 (t2228 v3.8.71 lifecycle retrospective) — bonus find #1 of 4. The helper refused by keyword-guard added ~5min to the parent-task PR lifecycle via forced manual body composition.

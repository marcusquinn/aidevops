<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2260: worktree-helper.sh add pattern-matches wrong issue number from brief body

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code (interactive, t2249 session)
- **Observation:** While creating a worktree during t2249, the helper applied interactive-claim state to merged PR #15114 instead of the intended new issue. Root cause: a greedy `#NNN` / `GH#NNN` regex scanned free-form text in the brief and matched the first reference to #15114 (which appeared in a historical "Context" section), not the current task's issue.

## What

`worktree-helper.sh add` auto-claims the wrong GitHub issue when the task brief's Context section mentions a different issue number. The pattern matcher scans unstructured text and grabs the first match.

## Why

Silent incorrect claims leak `status:in-review` + self-assign onto unrelated merged issues. Had to manually revert mid-session. The issue-ownership signal is safety-critical (it gates dispatch dedup) — any false positive burns trust in the mechanism and risks cascading damage on live repos.

## How

1. Identify the pattern-match location in `.agents/scripts/worktree-helper.sh` `add` handler — likely a `grep -oE '(GH)?#?[0-9]+'` or similar.
2. Constrain detection to ONE of:
   - Explicit CLI arg (`--issue NNN`).
   - Issue number derived from the branch name if it follows `<type>/<task-id>-<slug>` AND the task counter is session-scoped.
   - Issue number from an explicit dispatch-claim stamp file.
3. REMOVE free-form brief-body scanning — that signal is too weak.
4. Add regression test at `.agents/scripts/tests/test-worktree-helper-claim-scope.sh`:
   - Synthetic brief body referencing `#99999` in Context.
   - Run `worktree-helper.sh add` targeting a different issue.
   - Assert only the target issue gets a claim; #99999 remains untouched.

## Tier

Tier:standard. Design decision on which signals to keep vs drop; regression test needs non-trivial fixture setup.

## Acceptance

- [ ] Creating a worktree for a new task does NOT apply claim state to unrelated issues mentioned in the brief.
- [ ] Regression test at `.agents/scripts/tests/test-worktree-helper-claim-scope.sh` passes.
- [ ] All existing `worktree-helper.sh add` callers still work (backward compat check).

## Relevant files

- `.agents/scripts/worktree-helper.sh` — `add` handler and pattern-match logic
- `.agents/scripts/interactive-session-helper.sh` — downstream consumer of the claim signal
- `.agents/scripts/tests/` — regression test location

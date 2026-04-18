<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2222 Brief — Extend pre-commit duplicate-ID check to declined tasks and routine IDs

**Issue:** GH#19723 (marcusquinn/aidevops). **Blocked-by:** GH#19712 (t2209) — cannot edit the pre-commit hook without `--no-verify` until the t2209 base fix merges.

## Session origin

Discovered 2026-04-18 via Gemini Code Assist review on PR #19712. The diff-aware fix in #19712 correctly extracts task IDs from task-list defining lines, but its regex `\[[ x]\]` + `t[0-9]+` only covers active (`- [ ]`) and completed (`- [x]`) tasks with the `t` prefix. Two legitimate ID classes slip through:

- **Declined tasks** use `- [-]` per TODO.md `## Format` example at line 20 (`- [-] tZZZ Declined task`).
- **Routine IDs** under `## Routines` use the `r` prefix (`r001`, `r002`, ...) per AGENTS.md "Routines" section.

A declined task re-using an active task's ID, or two routines with the same r-ID, is a real collision that the current check silently tolerates.

## What / Why / How

See issue body for:

- Exact `oldString` / `newString` blocks for both sed invocations in `validate_duplicate_task_ids`
- Line references (`pre-commit-hook.sh:57-62`)
- Test extension pattern (build on existing 9-scenario harness at `.agents/scripts/tests/test-pre-commit-hook-duplicate-ids.sh`)

## Acceptance criteria

Listed in issue body. Core assertions:

1. `- [-] t500` + `- [ ] t500` on same commit → flagged as new duplicate.
2. `- [ ] r099` + `- [x] r099` on same commit → flagged as new duplicate.
3. Diff-aware historical tolerance from #19712 still holds for the new classes.
4. Existing 9 test scenarios still pass; 2 new scenarios added.

## Tier

`tier:simple` — two character-class tweaks in an existing regex, verbatim oldString/newString provided, 2-file scope (hook + test), fits within disqualifier limits.

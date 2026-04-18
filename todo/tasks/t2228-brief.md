<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2228 Brief — task-counter regression guard in pre-commit hook

**Issue:** GH#19749 (marcusquinn/aidevops — filed alongside this brief).

## Session origin

Discovered 2026-04-18 during PR #19730 (t2189 session follow-ups) preparation. Planning worktree's `.task-counter` was staged at 2204 while `origin/main` was at 2224 — a 20-ID wipe if committed. Only caught by manual diff check. Near-miss: if the commit had gone through, 20 claimed task IDs would have been silently overwritten.

`claim-task-id.sh` has CAS-based push logic (t2202 tracks a race bug there), but the pre-commit hook has no validator catching stale counter values.

## What / Why / How

See issue body for:

- New validator function `validate_task_counter_monotonic` in `.agents/scripts/pre-commit-hook.sh`
- Logic: if `.task-counter` is staged, compare `git show :.task-counter` to `git show HEAD:.task-counter`; staged < HEAD → fail
- Error message: "Counter regression detected (staged=N, HEAD=M). Likely a stale worktree. Run `git checkout origin/main -- .task-counter`."
- Model on `validate_duplicate_task_ids` shape (same file, same diff-aware pattern)

## Acceptance criteria

Listed in issue body. Core assertions:

1. Staging a counter value lower than HEAD rejects the commit with actionable message.
2. Staging a counter value equal to HEAD is allowed (no regression, possibly a merge).
3. Staging a counter value higher than HEAD is allowed (new claim).
4. Not staging `.task-counter` is a no-op (validator skipped).
5. Regression test under `.agents/scripts/tests/test-pre-commit-hook-counter-monotonic.sh`.

## Tier

`tier:simple` — single validator function, small file impact, test pattern from t2209 harness. All acceptance cases enumerable as fixture scenarios.

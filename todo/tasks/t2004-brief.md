<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2004: Phase 12 — split `_is_task_committed_to_main()` (189 lines)

## Origin

- **Created:** 2026-04-12, claude-code:interactive
- **Parent:** t1962 Phase 12 follow-up (plan §6, candidate #6)
- **Function location:** `.agents/scripts/pulse-dispatch-core.sh:455` (extracted in Phase 9, t1977 / #18390)

## What

Split `_is_task_committed_to_main()` into per-concern helpers. The function determines whether a task ID is already committed to main via several signals: commit message scan, file content scan, PR merge metadata. Each signal currently lives inline in the same function.

Target structure:
1. **`_task_id_in_recent_commits()`** — git log scan for `tNNN:` prefix in subject lines
2. **`_task_id_in_changed_files()`** — file content scan (TODO.md `[x]` markers, plan completion notes)
3. **`_task_id_in_merged_pr()`** — gh PR query for merged PRs whose title starts with task ID
4. Parent shrinks to: try each signal in order, return first hit. <40 lines.

## Why

- 189 lines, mid-tier survivor.
- This function is the heart of the "is this task done?" check used by dispatch dedup. Bugs here cause spurious dispatches (tasks already done get re-dispatched). Test coverage is the existing `test-pulse-wrapper-main-commit-check.sh` (8 assertions).
- Per-signal extraction makes each signal independently mockable in tests.

## Tier

`tier:standard`. Mechanical split with clear concern boundaries.

## How

### Files to modify

- **EDIT:** `.agents/scripts/pulse-dispatch-core.sh:455-643` — `_is_task_committed_to_main()` body
- **VERIFY:** `.agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh` — 8 assertions, exercises this exact function. Must pass after split.

### Recommended split

1. Read the function. Identify the 3-4 signal checks. They're typically separated by `# Signal N:` comments or by clear `if ... then return 0; fi` blocks.
2. Extract each signal into a private helper. Each takes (`task_id`, `repo_path`) and returns 0/1.
3. Parent becomes:
```bash
_is_task_committed_to_main() {
    local task_id="$1" repo_path="$2"
    _task_id_in_recent_commits "$task_id" "$repo_path" && return 0
    _task_id_in_merged_pr "$task_id" "$repo_path" && return 0
    _task_id_in_changed_files "$task_id" "$repo_path" && return 0
    return 1
}
```

### Verification

```bash
bash -n .agents/scripts/pulse-dispatch-core.sh
.agents/scripts/pulse-wrapper.sh --self-check
bash .agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh  # CRITICAL
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
SHELLCHECK_RSS_LIMIT_MB=4096 shellcheck .agents/scripts/pulse-dispatch-core.sh
```

## Acceptance Criteria

- [ ] `_is_task_committed_to_main()` reduced to under 40 lines
- [ ] 3 new helper functions extracted, each under 80 lines
- [ ] `test-pulse-wrapper-main-commit-check.sh` passes 8/8
- [ ] All other pulse tests pass
- [ ] `shellcheck` no new findings

## Relevant Files

- `.agents/scripts/pulse-dispatch-core.sh:455`
- `.agents/scripts/tests/test-pulse-wrapper-main-commit-check.sh`

## Dependencies

- **Related:** t1999 (sibling — same module)

## Estimate

~1.5h.

# t286: False Close Audit Report

**Date**: 2026-02-11
**Auditor**: AI DevOps (claude-opus-4-6)
**Scope**: All closed GitHub issues with `status:done` label vs TODO.md task status

## Methodology

1. Exported all 52 closed issues with `status:done` label
2. Cross-referenced each issue's task ID against TODO.md `[x]` status
3. Checked for parent tasks marked `[x]` with open subtasks
4. Checked for tasks marked `[x]` without `pr:` or `verified:` fields
5. Checked for task ID collisions

## Findings

### 1. False Closures (GitHub issue closed but task is `[ ]` in TODO.md)

| Issue | Task ID | Description | Action |
|-------|---------|-------------|--------|
| GH#851 | t001.1 | Example subtask in TODO.md format section | Reopen issue or remove `ref:GH#` from example |
| GH#852 | t001.1.1 | Example sub-subtask in TODO.md format section | Reopen issue or remove `ref:GH#` from example |
| GH#853 | t001.2 | Example subtask in TODO.md format section | Reopen issue or remove `ref:GH#` from example |

**Root cause**: The TODO.md format section contains example tasks with real `ref:GH#` links. The issue-sync pipeline created GitHub issues for these examples and then closed them when the format section was processed. These are not real tasks.

**Fix**: Remove `ref:GH#` from the example tasks in the format section, or use clearly fake refs like `ref:GH#000`.

### 2. Parent Tasks Marked `[x]` With Open Subtasks

| Task | GitHub Issue | Open Subtasks | Action |
|------|-------------|---------------|--------|
| t008 | GH#501 (CLOSED) | t008.1, t008.2, t008.3, t008.4 (all `[ ]`) | Revert t008 to `[ ]`, reopen GH#501 |
| t012 | GH#506 (CLOSED) | t012.1, t012.3, t012.4, t012.5 (all `[ ]`) | Revert t012 to `[ ]`, reopen GH#506 |

**Root cause**: The supervisor's auto-decomposition (t274) marked parent `#plan` tasks as `[x]` after generating subtasks, but the subtasks themselves are incomplete. The issue-sync pipeline then closed the GitHub issues.

**Fix**: Revert parent tasks to `[ ]` and reopen their GitHub issues.

### 3. Task ID Collision

| Task ID | Instance 1 | Instance 2 |
|---------|-----------|-----------|
| t274 | Supervisor auto-decomposition of #plan tasks (pr:#1066, GH#1064) | Move wavespeed.md from services/ai-generation/ to tools/video/ (no pr:, no ref:) |

**Root cause**: Parallel sessions assigned the same task ID. The collision prevention rule (re-read TODO.md after failed push) was not followed.

**Fix**: Renumber the wavespeed move task to the next available ID (t287).

### 4. Subtask With Wrong `ref:GH#`

| Task | Issue Ref | Actual Issue | Action |
|------|-----------|-------------|--------|
| t012.2 | ref:GH#1099 | GH#1099 is actually for t012.3 | Fix ref to correct issue |

### 5. Previously Fixed

| Task | Issue | Problem | Resolution |
|------|-------|---------|------------|
| t199.8 | GH#861 | Worker failed with `clean_exit_no_signal`, stub created instead of migration | Fixed in PR #1104 (this session) |

## Summary

| Category | Count | Severity |
|----------|-------|----------|
| False closures (example tasks) | 3 | Low (not real tasks) |
| Parent tasks with open subtasks | 2 | Medium (misleading completion) |
| Task ID collisions | 1 | Medium (data integrity) |
| Wrong issue refs | 1 | Low (cross-reference error) |
| Previously fixed | 1 | Resolved |

## Recommended Actions

1. Remove `ref:GH#` from TODO.md format examples (t001.x)
2. Revert t008 and t012 to `[ ]` in TODO.md
3. Reopen GH#501 and GH#506
4. Renumber duplicate t274 (wavespeed) to t287
5. Fix t012.2 ref to correct issue number

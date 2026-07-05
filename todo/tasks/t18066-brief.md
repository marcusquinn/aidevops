---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18066: Resolve full-loop rebase base branch from remote default

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `GH#26626 full-loop-helper-commit origin/main branch-aware rebase task dispatch` → 0 hits — no relevant lessons
- [x] Discovery pass: recent commits touching `TODO.md` / `todo/tasks` / `.agents/scripts/full-loop-helper-commit.sh` reviewed; recent full-loop helper PRs did not remove the hardcoded base branch; no open related PRs found by prework discovery
- [x] File refs verified: `.agents/scripts/full-loop-helper-commit.sh:195-218` and `.agents/scripts/full-loop-helper-commit.sh:526-560` checked, hardcoded `origin/main` / `main` refs were present before this task
- [x] Tier: `tier:standard` — disqualifier check clean (central commit/rebase/push path plus `.task-counter` race-prevention logic requires judgment and tests)
- [x] Seeded draft PR decision recorded: skipped — implementation is included directly in this interactive full-loop session

## Origin

- **Created:** 2026-07-05
- **Session:** OpenCode:interactive
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** GH#26626 was reviewed and approved as a real bug: `full-loop-helper-commit.sh` assumed `origin/main` in cross-repo commit/rebase automation, which fails for repos whose default branch is not `main`.

## What

Make `commit-and-pr` branch-base aware in `.agents/scripts/full-loop-helper-commit.sh`. The helper must resolve the remote default/base branch and use that branch consistently for ahead-count checks, fetch/rebase target selection, operator messages, and `.task-counter` drift reset.

## Why

`full-loop-helper-commit.sh::_rebase_and_push()` rebased worker branches onto `origin/main` even when the target repo's default branch was another branch such as `develop`. This can pull unrelated commits, abort rebases, and force workers into manual PR creation. The fix removes a cross-repo automation assumption while preserving t2229 `.task-counter` safety.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The change is localized, but not `tier:simple` because the main helper is large and the fix needs safe fallback/error behavior plus preservation of `.task-counter` race-prevention semantics.

## PR Conventions

Leaf task: use `Resolves #26626` in the implementation PR body.

## How (Approach)

### Files to Modify

- `.agents/scripts/full-loop-helper-commit.sh`
- `.agents/scripts/tests/test-full-loop-commit-default-branch.sh`

### Implementation Steps

1. Add `_resolve_rebase_base_branch()` to read `refs/remotes/origin/HEAD` and return the branch name only.
2. Use `origin/${base_branch}` for ahead count, fetch, rebase, user messages, and `.task-counter` reset.
3. Fail with `git remote set-head origin --auto` guidance when the remote default branch cannot be resolved.
4. Add shell regression coverage for `origin/develop`.

### Verification

- `.agents/scripts/tests/test-full-loop-commit-default-branch.sh`
- `shellcheck .agents/scripts/full-loop-helper-commit.sh .agents/scripts/tests/test-full-loop-commit-default-branch.sh`
- `.agents/scripts/verify-brief.sh todo/tasks/t18066-brief.md`

## Acceptance Criteria

- [ ] `commit-and-pr` no longer hardcodes `origin/main` / literal `main` in `_stage_and_commit()` and `_rebase_and_push()` for cross-repo ahead-count/rebase/counter-base behavior.
- [ ] Repos whose remote default branch is `develop` rebase onto `origin/develop` and read `.task-counter` from `origin/develop`.
- [ ] Missing/unresolvable remote default branch fails with actionable remediation instead of silently choosing `main`.
- [ ] Focused shell regression coverage proves the non-`main` base branch path.

## References

- GH#26626 — source issue and validation comment.
- GH#25780 / t18025 — prior fix for hardcoded base branch wording in `pulse-merge-conflict.sh`.
- GH#20487 / GH#20508 — prior default-branch detection pattern in pulse maintenance scripts.
- t2229 — `.task-counter` race-prevention invariant that must remain intact.

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18429: Fix in-progress task completion and planning PR title compatibility

## Pre-flight

- [x] Memory recall: `planning completion in-progress checkbox planning PR title squash validation` → 1 hit documenting both observed failures and the safe follow-up scope.
- [x] Discovery pass: 2 recent commits touched the target files; no related open or recently merged implementation PR was found.
- [x] File refs verified: all production files and focused tests listed below are tracked at current `origin/main`.
- [x] Tier: `tier:standard` — the behavior is bounded to planning publication and TODO completion, with clear regression surfaces.
- [x] Seeded draft PR decision recorded: skipped because this brief is being published for asynchronous worker dispatch.

## Origin

- **Created:** 2026-09-11
- **Session:** OpenCode interactive session
- **Created by:** ai-interactive with maintainer authorization
- **Conversation context:** Completion of t18428 exposed two deterministic helper defects: canonical `[>]` tasks were rejected by completion paths, and protected-main planning publication generated `plan(tNNN): ...` titles rejected by the repository squash-title validator.

## What

Make all supported task-completion paths accept canonical in-progress tasks and make planning-only PR titles valid without manual repair:

- Treat `[>]` as completable alongside `[ ]` while preserving `[x]` idempotency.
- Emit one valid task-prefixed or conventional planning PR title instead of the unsupported `plan(tNNN): ...` hybrid.
- Add focused positive, negative, and regression coverage for both behaviors.

## Why

The helpers currently disagree with the documented TODO lifecycle. A task may be marked in progress as `[>]`, but completion commands only search for `[ ]`, so verified work cannot be recorded. On protected default branches, `_todo_planning_pr_title` generates a title that the full-loop squash validator rejects, forcing manual `gh pr edit` repair before merge.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The change spans several shell completion paths and protected-branch planning publication, but the required behavior and compatibility boundaries are explicit and locally testable.

## PR Conventions

This is a leaf issue. The implementation PR must use `Resolves #31805` and a valid `t18429: ...` title.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The task is intended for asynchronous worker dispatch after canonical brief publication.
- **Status:** `not-created`
- **Freshness evidence:** Target files, recent commits, and open/merged related PRs were checked against current `origin/main` on 2026-09-11.
- **Verification run:** `prework-discovery-helper.sh` completed; implementation checks remain pending.
- **Stale-assumption warning:** Revalidate if another PR changes TODO checkbox syntax, `_todo_planning_pr_title`, or full-loop title validation.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/planning-commit-helper.sh`
- EDIT: `.agents/scripts/task-complete-helper.sh`
- EDIT: `.agents/scripts/version-manager-git.sh`
- EDIT: `.agents/scripts/shared-todo-commit.sh`
- EDIT: `.agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh`
- EDIT: `.agents/scripts/tests/test-task-complete-move.sh`
- EDIT: `.agents/scripts/tests/test-task-complete-pr-verify.sh`
- EDIT: `.agents/scripts/tests/test-version-manager-task-id-extraction.sh`

### Complete Write Surface

- **Callers/readers:** `planning-commit-helper.sh`, `task-complete-helper.sh`, and `version-manager-git.sh` read canonical task rows; `full-loop-helper.sh` reads the generated PR title during squash validation.
- **Writers/mutation paths:** `planning-commit-helper.sh`, `task-complete-helper.sh`, and `version-manager-git.sh` mutate task state and proof metadata; `shared-todo-commit.sh` creates protected-main planning branches and PRs.
- **Tests/fixtures:** `test-planning-commit-helper-protected-default-pr.sh`, `test-task-complete-move.sh`, `test-task-complete-pr-verify.sh`, and `test-version-manager-task-id-extraction.sh` cover the existing paths and will hold new fixtures.
- **Schemas/config:** N/A because existing task checkbox states and title policy are already defined; only consumers/producers are inconsistent.
- **Generated/deployed mirrors:** N/A because these helpers are source scripts deployed by the normal release pipeline, which is outside this implementation PR.
- **Migrations/backfills:** No migration/backfill is applicable because existing `[>]` rows remain valid and become completable after deployment without rewriting historical TODO data.
- **Cleanup/rollback paths:** Revert the implementation PR; planning worktree cleanup remains owned by `shared-todo-commit.sh` and must continue removing temporary worktrees after publication.

### Implementation Steps

1. Update each TODO completion matcher and replacement so both `[ ]` and `[>]` transition to `[x]` with existing proof metadata.
2. Keep `[x]` idempotent and ensure malformed, missing, duplicate, or child-task cases retain their current fail-closed handling.
3. Change `_todo_planning_pr_title` so a single-task planning PR uses the repository-supported `tNNN: subject` form; preserve the existing multi-task/conventional fallback.
4. Extend focused shell tests for unchecked, in-progress, completed, missing, and protected-main title cases.
5. Run focused tests, ShellCheck on changed shell files, and changed-file lint.

### Hazards and Compatibility

- **Concurrency/atomicity:** Preserve the existing planning lock, publication ID, temporary worktree, and branch-collision checks in `shared-todo-commit.sh`; title formatting must not alter publication identity.
- **Migration/rollback:** Existing `[>]`, `[ ]`, and `[x]` rows require no migration; reverting restores prior matching and title generation without data conversion.
- **Mixed-version/backward compatibility:** New completion consumers must accept old canonical rows, and generated `tNNN: ...` titles must remain consumable by current full-loop and issue-sync readers.
- **Idempotency/retry:** Preserve `[x]` no-op behavior, proof-field deduplication, exact task-ID boundaries, reused planning PR detection, and retry-safe publication.
- **Partial failure/recovery:** A failed TODO write or PR creation must keep current fail-closed cleanup/receipt behavior; do not leave a task partially completed or weaken planning worktree recovery.

### Verification Before Dispatch

```bash
.agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh
.agents/scripts/tests/test-task-complete-move.sh
.agents/scripts/tests/test-task-complete-pr-verify.sh
.agents/scripts/tests/test-version-manager-task-id-extraction.sh
shellcheck .agents/scripts/planning-commit-helper.sh .agents/scripts/task-complete-helper.sh .agents/scripts/version-manager-git.sh .agents/scripts/shared-todo-commit.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The three completion tests prove `[ ]`, `[>]`, `[x]`, proof-log, Done-section, and exact-ID behavior across all mutation paths; the protected-default test proves task-manifest title generation and planning cleanup; ShellCheck covers changed shell syntax; changed-file lint covers repository policy.
- **Broad verification trigger:** Not required because the change does not alter shared schemas, root tooling, dependencies, release infrastructure, or cross-package contracts.

### Hard Boundaries

Do not weaken full-loop title validation, change task-ID allocation, or alter issue-sync `[skip ci]` behavior. Directly necessary adjacent integration requires documenting and verifying the minimal corrected scope with the interactive brief owner before editing.

### Files Scope

- `.agents/scripts/planning-commit-helper.sh`
- `.agents/scripts/task-complete-helper.sh`
- `.agents/scripts/version-manager-git.sh`
- `.agents/scripts/shared-todo-commit.sh`
- `.agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh`
- `.agents/scripts/tests/test-task-complete-move.sh`
- `.agents/scripts/tests/test-task-complete-pr-verify.sh`
- `.agents/scripts/tests/test-version-manager-task-id-extraction.sh`

## Acceptance Criteria

- [ ] `planning-commit-helper.sh complete` completes canonical `[ ]` and `[>]` tasks with identical proof metadata.
- [ ] `task-complete-helper.sh` and `version-manager-git.sh` complete `[>]` without regressing `[ ]`, `[x]`, exact-ID boundaries, subtasks, or Done-section behavior.
- [ ] Single-task protected-main planning publication emits a validator-compatible `tNNN: ...` title without manual repair.
- [ ] Multi-task and issue-sync planning title behavior remains compatible.
- [ ] Focused tests include positive `[>]` transitions and negative/idempotent cases.
- [ ] Changed shell files pass ShellCheck and the repository changed-file lint gate.

## Rollback

Revert the implementation PR. This restores unchecked-only completion and the prior planning-title format without altering task IDs, issue state, or repository history.

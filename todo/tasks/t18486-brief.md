---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18486: claim-task-id must not write TODO.md into a canonical checkout

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `claim-task-id canonical TODO` → 0 hits
- [x] Discovery pass: `gh search issues "claim-task-id canonical TODO.md"` and `"claim-task-id dirty canonical"` → 0 open or closed matches; related but distinct: #32247 (counter CAS isolated from canonical, merged) and #32453 (canonical staleness)
- [x] File refs verified: `.agents/scripts/claim-task-id-issue.sh` (842 lines; `_ensure_todo_entry_written` at :674, `_converge_created_issue_ref` at :754), `.agents/scripts/issue-sync-lib-ref.sh:411` (`require_task_issue_mapping`), `.agents/scripts/project-config-restore-helper.sh:113`, `.agents/scripts/tests/test-claim-task-id-todo-collision.sh`
- [x] Tier: `tier:standard` — a bounded guard in one helper, but the mapping hazard below needs care

## Origin

- **Created:** 2026-09-27
- **Created by:** ai-interactive
- **Conversation context:** In two interactive claims on 2026-09-27 (t18378 in a managed downstream repo, t18485 here), `--repo-path` pointed at a canonical checkout. `claim-task-id.sh` appended the TODO.md entry there, leaving a read-only service mirror dirty until `canonical-recovery-helper.sh sync-mirror` backed it up and converged it. A third claim with `--repo-path` set to a linked worktree (this task, t18486) wrote the line into the worktree as intended.

## What

When the resolved `--repo-path` is a canonical checkout rather than a linked worktree, `claim-task-id.sh` completes the counter claim and issue creation but does not modify that checkout's TODO.md. Instead it prints the exact task line with a hint to add it in a linked worktree, and exits 0.

## Why

Canonical checkouts are read-only service mirrors (AGENTS.md "Git workflow"; `reference/dirty-worktree-preservation.md`). Counter CAS already uses an isolated Git context (#32247). The TODO convergence path is the remaining writer into the caller's working tree, so every interactive claim run from a canonical path silently dirties it and forces a mirror recovery before the next merge sync.

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?** Guard location, detection pattern and output contract are given.
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** The worker confirms the deferred-mapping path below with a test.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?** It reuses the existing ref backfill.
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** `claim-task-id-issue.sh` is not listed in `.agents/configs/self-hosting-files.conf` (checked 2026-09-27).

**Selected tier:** `tier:standard`

**Tier rationale:** A small guard, but it sits on the claim path that every task creation uses, and it interacts with the immutable task-to-issue mapping.

## PR Conventions

Leaf task: the PR uses `Resolves` with this task's issue number.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/claim-task-id-issue.sh:660-782`, which contains the TODO write and convergence.
- **Load only if:** `.agents/scripts/issue-sync-lib-ref.sh:360-423` shows how the mapping is resolved from the TODO `ref:GH#` and backfilled (`source ref-gh-backfill`).
- **Why:** the convergence function currently fails the claim when the TODO ref is absent.
- **Stop when:** the guard placement and the deferred-mapping behaviour are clear.

### Files to Modify

- `EDIT: .agents/scripts/claim-task-id-issue.sh:754` (`_converge_created_issue_ref`): return 0 before any write when `repo_path` is a canonical checkout, after printing the would-be line.
- `EDIT: .agents/scripts/claim-task-id-issue.sh:674` (`_ensure_todo_entry_written`): factor the line-building (lines 694-739) into a helper so the canonical branch can print the identical line without writing.
- `EDIT: .agents/scripts/tests/test-claim-task-id-todo-collision.sh`: add canonical and linked-worktree cases, or add a sibling test modelled on it.

### Complete Write Surface

- **Callers/readers:** `_converge_created_issue_ref` is called from `claim-task-id.sh` on the delegation path (around line 591) and the bare-fallback path (around line 750); both treat a return of 1 as a failed claim.
- **Writers/mutation paths:** `_insert_todo_line` in `.agents/scripts/claim-task-id-issue.sh` is the only TODO writer in this path; the guard must prevent it for canonical paths.
- **Tests/fixtures:** `.agents/scripts/tests/test-claim-task-id-todo-collision.sh` builds temporary repos; extend it with a canonical repo and a linked worktree created by `git worktree add`.
- **Schemas/config:** N/A because the guard adds no config key; `.agents/configs/self-hosting-files.conf` does not list `claim-task-id-issue.sh` (checked 2026-09-27).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/*` to `~/.aidevops/agents/scripts/`; no index update.
- **Migrations/backfills:** N/A because existing TODO lines and mappings are untouched; new canonical-path claims rely on the existing `ref-gh-backfill` bind in `.agents/scripts/issue-sync-lib-ref.sh:396` once the line lands through a PR.
- **Cleanup/rollback paths:** revert the guard in `.agents/scripts/claim-task-id-issue.sh`; no state to clean.

### Implementation Steps

1. Add `_claim_repo_is_canonical_checkout REPO_PATH`: return 0 when `git -C REPO_PATH rev-parse --path-format=absolute --git-dir` equals `--git-common-dir` (pattern: `.agents/scripts/project-config-restore-helper.sh:113`). Return 1 on any git error (fail open to today's behaviour, not closed).
2. Extract `_build_todo_line TASK_ID TITLE LABELS ISSUE_NUM` from `_ensure_todo_entry_written` (lines 694-739) without changing its output.
3. In `_converge_created_issue_ref`, before the retry loop: when canonical, print `TODO_LINE=<line>` on stdout and a `log_warn` hint ("canonical checkout is read-only; add this line in a linked worktree"), then return 0.
4. Add the tests from Acceptance.

### Hazards and Compatibility

- **Concurrency/atomicity:** none added; the guard is a read-only git query before any write.
- **Migration/rollback:** none; revert restores today's write.
- **Mixed-version/backward compatibility:** callers that parse `task_id=` and `ref=` on stdout keep working; `TODO_LINE=` is an additional key. Check `.agents/scripts/tests/test-claim-task-id-stdout-isolation.sh` still passes.
- **Idempotency/retry:** re-running a claim is unchanged; the canonical branch has no side effects.
- **Partial failure/recovery:** if canonical detection errors, the helper falls back to today's behaviour, so claims never fail because of the guard. The immutable mapping for canonical-path claims is bound later by the existing backfill; confirm with a test that `require_task_issue_mapping` is not invoked on the canonical branch.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-claim-task-id-todo-collision.sh
bash .agents/scripts/tests/test-claim-task-id-stdout-isolation.sh
shellcheck .agents/scripts/claim-task-id-issue.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the collision test proves both path types; the stdout-isolation test proves the output contract; ShellCheck and the linters cover conventions.
- **Broad verification trigger:** run all `test-claim-task-id-*.sh` if the extraction in step 2 changes any existing TODO line output.

### Scope Boundaries

**Hard boundaries:** do not change counter CAS, issue creation, labels or sub-issue linking; do not auto-create worktrees from the helper.

**AI brief owner:** maintainer interactive session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/claim-task-id-issue.sh`
- `.agents/scripts/tests/test-claim-task-id-todo-collision.sh`
- `TODO.md`
- `todo/tasks/t18486-brief.md`

## Acceptance Criteria

- [ ] With `--repo-path` at a canonical checkout, TODO.md is byte-identical after the claim, the exit status is 0, and stdout contains `TODO_LINE=` with the exact task line.

  ```yaml
  verify:
    method: codebase
    pattern: "_claim_repo_is_canonical_checkout"
    path: ".agents/scripts/claim-task-id-issue.sh"
  ```

- [ ] With `--repo-path` at a linked worktree, the TODO line is written exactly as before.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-todo-collision.sh"
  ```

- [ ] Regression guard: counter CAS, issue creation, labels, auto-assign rules and sub-issue linking must not change, and headless workers in linked worktrees must not regress.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-stdout-isolation.sh"
  ```

- [ ] ShellCheck is clean and `linters-local.sh --changed` passes.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/claim-task-id-issue.sh"
  ```

## Context & Decisions

- Chosen: skip the write and print the line. Ruled out: writing into the canonical checkout and committing it (violates the read-only mirror rule), and auto-creating a worktree from the helper (hidden side effects on a claim path).
- Fail open: a git error in detection keeps today's behaviour, so the guard can never block task creation.

## Relevant Files

- `.agents/scripts/claim-task-id-issue.sh:674` — TODO writer.
- `.agents/scripts/claim-task-id-issue.sh:754` — convergence and mapping.
- `.agents/scripts/issue-sync-lib-ref.sh:396` — `ref-gh-backfill` binding.
- `.agents/scripts/project-config-restore-helper.sh:113` — canonical detection pattern.

## Dependencies

- **Blocked by:** none
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | two functions, mapping path |
| Implementation | 30m | guard, line builder |
| Verification | 15m | tests, ShellCheck |
| **Total** | **~1h** | |

---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18494: fix: claim-task-id strands IDs on rejected bodies, misleading scope hint, polluted issue-number capture, 30s counter fetch budget

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `claim-task-id stranded id counter timeout` → 0 hits
- [x] Discovery pass: #32605 (in review) owns the brief-template vs `brief_scope.py` mismatch; this task excludes it. #32561 (merged) introduced the canonical-checkout TODO advisory.
- [x] File refs verified:
  - `.agents/scripts/claim-task-id.sh`: `_main_create_issues` at :1123, `issue_num=$(create_github_issue …)` at :1151, `eval` of `_issue_*` at :1852, `CAS_HTTPS_TIMEOUT_S` at :177
  - `.agents/scripts/claim-task-id-issue.sh`: the canonical advisory `printf` to stdout at :749
  - `.agents/scripts/brief_scope.py`: `fail()` at :16
- [x] Tier: `tier:standard`, on the task-creation path used by every session

## Origin

- **Created:** 2026-09-27
- **Created by:** ai-interactive
- **Issue:** GH#32617
- **Conversation context:** An interactive session filing five learnings issues with `claim-task-id.sh --description` stranded two IDs (t18488 and t18489). It needed a raised fetch budget. Every successful creation printed a malformed `Created issue: GH#TODO.md was not changed…` line and `line 1854: was: command not found`.

## What

Make interactive issue filing through `claim-task-id.sh` reliable:

- Never strand a task ID when the body is rejected.
- Give an accurate recovery hint.
- Keep issue-number capture and `ref=` output clean.
- Stop timing out on the first isolated counter fetch.

## Why

1. **Stranded IDs.** `brief_scope.py` rejects the composed body (`Files Scope requires owned author-side repair`) only after the CAS counter has advanced. The helper then prints "Task ID is secured" and creates nothing.
2. **Misleading hint.** The recovery text says to "use explicit EDIT:/NEW: paths". For an existing `### Files Scope` heading, `existing_scope()` accepts only bare `- path` bullets; `EDIT:`-prefixed bullets fail too.
3. **Polluted capture.** `claim-task-id-issue.sh:749` prints the canonical-checkout advisory to stdout, inside the call chain captured by `issue_num=$(create_github_issue …)` (`claim-task-id.sh:1151`). The "issue number" therefore becomes the advisory text followed by the number. `log_success` prints the corrupted value, and the `eval` at :1852 evaluates part of it (`was: command not found`). The `ref=GH#NNN` output is missing (`ref=none`) even though the issue exists.
4. **Fetch budget.** A fresh isolated Git context timed out fetching `origin/task-id-counter` at the default `CAS_HTTPS_TIMEOUT_S=30`, on both HTTPS and SSH (`fetch_rc=124`), while `git ls-remote` answered immediately. The fetch succeeded with 150 s. With three concurrent claims, each exceeded 150 s.

## Tier

### Tier checklist (verify before assigning)

- [x] **Exact execution contract supplied?**
- [x] **Targets and reference pattern verified?**
- [ ] **No semantic or design decision remains?** The worker chooses between pre-allocation body validation and an explicit rollback marker.
- [x] **Bounded, reversible, low-consequence impact?**
- [x] **No stateful coordination to invent?** Uses the existing t2800 pre-validation precedent.
- [x] **Focused verification and rollback are explicit?**
- [x] **No dispatch-path risk override?** `claim-task-id.sh` is listed in `.agents/configs/self-hosting-files.conf` (t2821 advisory), so run the claim tests from the worktree copy.

**Selected tier:** `tier:standard`

**Tier rationale:** Four bounded fixes on a shared path, with an existing test harness and a clear precedent.

## PR Conventions

Leaf task: the PR uses `Resolves #32617`.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/claim-task-id.sh:1123-1175` (`_main_create_issues`), `.agents/scripts/claim-task-id-issue.sh:700-769` (TODO projection and advisory), `.agents/scripts/brief_scope.py` (accepted shapes).
- **Load only if:** `.agents/scripts/claim-task-id-counter.sh`, around the isolated context and fetch (near :250-290), when changing the fetch budget.
- **Stop when:** the stdout contract of `create_github_issue` and the body-normalization call site are clear.

### Files to Modify

- `EDIT: .agents/scripts/claim-task-id-issue.sh:749`: send the canonical advisory to stderr (`>&2`) and keep the `TODO_LINE` data out of the captured stdout. Emit a separate `TODO_LINE=` key only at the top level, if at all.
- `EDIT: .agents/scripts/claim-task-id.sh`:
  - Run body normalization (the same `brief_scope.py prepare` path used at creation) before allocation, next to the t2800 label pre-validation. Exit 3 with the path-specific hint without advancing the counter.
  - Validate `issue_num` as `^[0-9]+$` before logging and `eval`.
  - Replace `eval` with explicit key parsing.
- `EDIT: .agents/scripts/claim-task-id-counter.sh`: use a shallow `--depth=1` fetch of the counter branch in the isolated context, or raise the default budget. On a double timeout, name `CAS_HTTPS_TIMEOUT_S` in the error.
- `EDIT: .agents/scripts/tests/test-claim-task-id-no-orphan.sh`: add a rejected-body case (counter unchanged) and a canonical-path case (`ref=GH#N` present, no stderr shell error).

### Complete Write Surface

- **Callers/readers:** `/new-task` (`scripts/commands/new-task.md`), `planning-commit-helper.sh next-id`, `shared-phase-filing.sh` and interactive sessions; all parse the `task_id=` and `ref=` stdout lines.
- **Writers/mutation paths:** the counter CAS push (`claim-task-id-counter.sh`), issue creation (`create_github_issue`) and TODO projection (`_ensure_todo_entry_written`).
- **Existing verification/tests:** `test-claim-task-id-no-orphan.sh`, `test-claim-task-id-stdout-isolation.sh`, `test-claim-task-id-todo-collision.sh` and `test-claim-task-id-status-default.sh`.
- **Schemas/config:** the stdout key contract (`task_id=`, `ref=`, `target_repo=`) and the env knobs `CAS_HTTPS_TIMEOUT_S` and `CAS_WALL_TIMEOUT_S`.
- **Generated/deployed mirrors:** `setup.sh` deploys the scripts.
- **Migrations/backfills:** N/A because no stored format changes; stranded IDs t18488 and t18489 remain unused gaps.
- **Cleanup/rollback paths:** `git revert` of the PR commit; the counter semantics are unchanged.

### Implementation Steps

1. Move the advisory at `claim-task-id-issue.sh:749` to stderr. Confirm that `create_github_issue` stdout is only the number.
2. Add the numeric guard for `issue_num` and replace the `eval` at `claim-task-id.sh:1852` with a `while IFS='=' read` parser restricted to `_issue_*` keys.
3. Move body normalization before allocation, following the t2800 label pre-validation structure (`_validate_labels_exist`). Make the hint path-specific.
4. Adjust the counter fetch (shallow, or with a larger default) and improve the timeout message.
5. Add the test cases, then run all `test-claim-task-id-*.sh`.

### Hazards and Compatibility

- **Concurrency/atomicity:** the CAS loop is unchanged. Pre-validation runs before any counter read, so it adds no race.
- **Migration/rollback:** a revert restores the current behaviour; no stored format changes.
- **Mixed-version/backward compatibility:** the stdout keys are unchanged. The advisory moves from stdout to stderr, and no consumer parses it (verify with `rg -n "was not changed in canonical"`).
- **Idempotency/retry:** a rejected body no longer consumes an ID, so retries are clean.
- **Partial failure/recovery:** if normalization tooling is missing, keep the current post-allocation path (fail open) and warn.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-claim-task-id-no-orphan.sh
bash .agents/scripts/tests/test-claim-task-id-stdout-isolation.sh
bash .agents/scripts/tests/test-claim-task-id-todo-collision.sh
shellcheck .agents/scripts/claim-task-id.sh .agents/scripts/claim-task-id-issue.sh .agents/scripts/claim-task-id-counter.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** no-orphan proves criterion 1 (IDs are only consumed by accepted bodies); stdout-isolation and todo-collision prove criteria 2 and 3 (clean `ref=` output, unchanged TODO projection); ShellCheck and the linter cover conventions.
- **Broad verification trigger:** run every `test-claim-task-id-*.sh` because this is a shared creation path.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `bash .agents/scripts/tests/test-claim-task-id-no-orphan.sh`
- [ ] WIP commit created before broad gates: `wip: claim-task-id stdout and pre-allocation validation`
- [ ] Evidence-triggered broad verification then run: all `test-claim-task-id-*.sh`

### Scope Boundaries

**Hard boundaries:** keep counter CAS semantics and existing scope-safety refusals intact; don't change the `brief_scope.py` rules or brief template owned by #32605.

**AI brief owner:** interactive maintainer session that filed this task.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/claim-task-id.sh`
- `.agents/scripts/claim-task-id-counter.sh`
- `.agents/scripts/claim-task-id-issue.sh`
- `.agents/scripts/tests/test-claim-task-id-no-orphan.sh`
- `TODO.md`
- `todo/tasks/t18494-brief.md`

## Acceptance Criteria

- [ ] A `--description` that the body normalizer rejects fails before the counter advances, leaving no stranded ID, and the hint names the accepted bare-bullet form.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-no-orphan.sh"
  ```

- [ ] A successful creation from a canonical `--repo-path` prints `ref=GH#NNN` on stdout, and the TODO advisory appears on stderr only.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-stdout-isolation.sh"
  ```

- [ ] Regression guard: ambiguous or contradictory scopes are still refused, CAS contention still retries safely, and linked-worktree TODO projection is unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-todo-collision.sh"
  ```

## Context & Decisions

- Chosen: pre-allocation validation, following the t2800 label precedent. Rejected: a "rollback" counter decrement, because the CAS counter must stay monotonic.
- #32605 fixes the template so template-conformant scopes pass. This task makes rejected bodies harmless whatever their cause.

## Relevant Files

- `.agents/scripts/claim-task-id.sh:1151` — issue number capture.
- `.agents/scripts/claim-task-id.sh:1852` — `eval`.
- `.agents/scripts/claim-task-id-issue.sh:749` — stdout advisory.
- `.agents/scripts/brief_scope.py:36` — `existing_scope`.

## Dependencies

- **Blocked by:** GH#32605 (template/validator alignment; soft ordering only)
- **Blocks:** none
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 20m | three scripts |
| Implementation | 45m | four fixes |
| Verification | 25m | claim tests |
| **Total** | **~1.5h** | |

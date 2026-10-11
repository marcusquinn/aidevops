<!-- aidevops:brief-schema=v2 -->

# fix(planning): skip only repo-verify on the dependency-free planning publication push

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `planning-commit-helper pre-push repo-verify typecheck tsc not found planning worktree` → 0 hits
- [x] Discovery pass: `prework-discovery-helper.sh` found no open PR on `.agents/scripts/shared-todo-commit.sh`; sibling defect GH#34434 (release pushes, closed by #34437) fixed the same failure for release worktrees only
- [x] File refs verified at origin/main 96aea889f5: planning push `.agents/scripts/shared-todo-commit.sh:569`; disposable worktree `:524`; planning-path filter `_todo_safe_planning_path` `:239-245`; hook bypass `.agents/hooks/repo-verify-pre-push.sh:52`; reference pattern `.agents/scripts/version-manager-protected-main.sh:42-49`, `:364-366`
- [x] Tier: `tier:simple` — one command gains an environment prefix plus a comment
- [x] Seeded draft PR decision recorded: skipped — the edit is fully specified below

## Origin

- **Created:** 2026-10-12
- **Session:** opencode:interactive
- **Created by:** ai-interactive
- **Conversation context:** `planning-commit-helper.sh "plan: add t18676 ..."` stopped at `local-recovery-ref` three times; the third run with `AIDEVOPS_LOG_FILE` set showed the planning branch push rejected by repo-verify.

## What

`planning-commit-helper.sh` publishes planning-only changes from an interactive linked worktree again: the PR fallback pushes its planning branch and opens the planning PR instead of stopping at `AIDEVOPS_PLANNING_RECOVERY_REMOTE_STATE=local-recovery-ref`.

## Why

- Evidence (2026-10-11T23:40Z, log captured with `AIDEVOPS_LOG_FILE`): the push from the disposable planning worktree ran `bun run typecheck`, failed with `tsc: command not found`, and repo-verify reported `[BLOCK] typecheck could not start: missing JavaScript dev dependencies`, then `Planning PR fallback failed: branch push failed`.
- Cause: `_todo_create_planning_worktree` creates a fresh `git worktree add --detach ... origin/<default>` checkout with no `node_modules` (`shared-todo-commit.sh:524`). Since 06df947aa5 / #34443 install the pre-push guard chain into the effective `core.hooksPath`, repo-verify runs in that worktree. GH#34434 fixed exactly this for the release pushes; the planning push was not covered.
- Impact: every planning-only publication through the PR fallback (TODO rows, briefs, `plan:` commits on protected `main`) fails; the last merged `planning/*` PR is #34225 (2026-10-10), before the guard move.

## Tier

**Selected tier:** `tier:simple`

**Tier rationale:** a single push command gets the same one-command bypass GH#34434 already applied to release pushes; the exact text is below.

## How

### Files to Modify

- `EDIT: .agents/scripts/shared-todo-commit.sh` — prefix the planning branch push in `_todo_commit_planning_worktree` with `AIDEVOPS_PREPUSH_REPO_VERIFY=0` and document the trust boundary.

### Complete Write Surface

- **Callers/readers:** `planning-commit-helper.sh` (`todo_commit_push "$repo_root" "$commit_msg" "TODO.md todo/"` at `:316`, `:594`) and other `todo_commit_push` callers reach `_todo_create_planning_pr` → `_todo_commit_planning_worktree` only on the protected-default PR fallback.
- **Writers/mutation paths:** `.agents/scripts/shared-todo-commit.sh:569` is the only push from the disposable worktree; the direct pushes at `:807` and `:823` run from the caller's checkout and keep full verification.
- **Existing verification/tests:** `.agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh` and `.agents/scripts/tests/test-planning-publication-lifecycle.sh` cover the PR fallback; the production check is a real `planning-commit-helper.sh` run from a linked worktree.
- **Schemas/config:** N/A because no config key is added; `AIDEVOPS_PREPUSH_REPO_VERIFY` is the existing documented bypass in `.agents/hooks/repo-verify-pre-push.sh:30-53`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` into the runtime bundle; no generated copy.
- **Migrations/backfills:** N/A because the helper keeps no stored state beyond the existing `refs/aidevops/planning/<id>` recovery ref, which this change does not alter.
- **Cleanup/rollback paths:** `git revert` of the fix commit restores the guarded push; recovery refs and retry-by-publication-ID behaviour are unchanged.

### Implementation Steps

1. In `.agents/scripts/shared-todo-commit.sh`, `_todo_commit_planning_worktree` (`:569`, single occurrence):

   ```text
   oldString:
   	git -C "$worktree_path" push origin "HEAD:refs/heads/${branch_name}" >/dev/null 2>>"$log_target" || {
   newString:
   	#aidevops:trust-boundary
   	# The planning worktree is a fresh, dependency-free checkout of
   	# origin/<default>, so the repo-verify pre-push guard (format/lint/typecheck)
   	# cannot start there (same failure as GH#34434 for release worktrees). This
   	# push carries only TODO.md and todo/* files (_todo_safe_planning_path) and
   	# the planning PR still runs CI, so skip only repo-verify for this one
   	# command; the privacy, credential, complexity, scope and duplicate-TODO
   	# guards still run.
   	AIDEVOPS_PREPUSH_REPO_VERIFY=0 git -C "$worktree_path" push origin "HEAD:refs/heads/${branch_name}" >/dev/null 2>>"$log_target" || {
   ```

2. Run the verification commands below.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because the change adds an environment prefix to one existing push; branch naming, publication-ID reuse and recovery refs are unchanged.
- **Migration/rollback:** no ordering concerns; reverting restores the current (failing) guarded push.
- **Mixed-version/backward compatibility:** older hooks that do not know the variable ignore it and behave as today; the variable is honoured by every deployed `repo-verify-pre-push.sh` since its introduction.
- **Idempotency/retry:** retries reuse the same publication ID and branch as before; a pushed branch is detected by `ls-remote` and reused.
- **Partial failure/recovery:** if the push still fails (network, other guards), the existing `local-recovery-ref` path and retry message are unchanged.

### Verification Before Dispatch

```bash
shellcheck -x .agents/scripts/shared-todo-commit.sh
bash .agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh
bash .agents/scripts/tests/test-planning-publication-lifecycle.sh
```

- **Surface mapping:** production proof is `planning-commit-helper.sh "plan: ..."` from a linked worktree with planning-only edits on a repo whose pre-push chain includes repo-verify; it must print a planning PR URL instead of `local-recovery-ref`.
- **Broad verification trigger:** Not required — no shared contract, root tooling or release infrastructure change.

### Scope Boundaries

**Hard boundaries:** do not change repo-verify itself, other guards, the direct pushes at `:807`/`:823`, or publication-ID/branch logic.

**Not in scope (follow-up):** provisioning JS dependencies in disposable worktrees.

**AI brief owner:** interactive maintainer session that filed this task.

### Files Scope

- `.agents/scripts/shared-todo-commit.sh`

## Acceptance Criteria

- [ ] The planning branch push sets `AIDEVOPS_PREPUSH_REPO_VERIFY=0` for that command only.

  ```yaml
  verify:
    method: codebase
    pattern: "AIDEVOPS_PREPUSH_REPO_VERIFY=0 git -C \"\\$worktree_path\" push origin"
    path: ".agents/scripts/shared-todo-commit.sh"
  ```

- [ ] ShellCheck reports no findings for the changed file.

  ```yaml
  verify:
    method: bash
    run: "shellcheck -x .agents/scripts/shared-todo-commit.sh"
  ```

- [ ] The protected-default planning PR fallback test still passes.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh"
  ```

- [ ] A real `planning-commit-helper.sh` run from a linked worktree opens a planning PR instead of stopping at `local-recovery-ref`.

  ```yaml
  verify:
    method: manual
    prompt: "Run planning-commit-helper.sh with planning-only edits from a linked worktree and confirm it prints a planning PR URL"
  ```

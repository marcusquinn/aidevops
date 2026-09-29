<!-- aidevops:brief-schema=v2 -->

# t18552: Worktree cleanup: audited local-branch cleanup so merged branches do not accumulate after worktree removal

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** An interactive pulse-review session removed its worktrees but left 9 merged local branches in the canonical repo. No sanctioned route could delete them, and running the canonical Git guard on the argv showed that `git branch -D` from canonical is blocked. The maintainer asked for this to be captured for auto-dispatch. Issue: GH#33030.

## What

A dry-run-by-default `local-branch-cleanup-helper.sh` deletes only local branches with merge evidence, using a compare-and-delete lease from an isolated linked-worktree transport, and records each deletion with its SHA. `worktree-helper.sh remove` and `clean` use it in single-branch mode, so merged branches no longer accumulate. `aidevops cleanup local-branches` exposes the bulk audit.

## Why

- `_remove_finalize_post_removal` keeps the removed worktree's branch (`.agents/scripts/worktree-helper-cmds.sh:334-352`).
- `clean` runs `git branch -D "$worktree_branch" 2>/dev/null || true` (`.agents/scripts/worktree-clean-lib.sh:1591-1594`). In interactive sessions the runtime `git` shim blocks it, because `.agents/scripts/canonical_git_readonly.py:13-42` classes `-d`/`-D` as mutations. The failure is hidden.
- `aidevops cleanup branches` only handles remote branches (`aidevops.sh:2010-2033`, `.agents/scripts/remote-branch-cleanup-helper.sh`).
- Observed on 2026-09-29: 9 orphaned local branches from one session. Six are ancestors of `origin/main`; three were squash-merged. Each needs manual `git branch -D`, which interactive sessions are told never to run in canonical.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: a new helper closely modelled on `.agents/scripts/remote-branch-cleanup-helper.sh`, with explicitly specified safety predicates, plus three one-call integrations. No dispatch-path or pulse files change.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/local-branch-cleanup-helper.sh` — model on `.agents/scripts/remote-branch-cleanup-helper.sh`:
  - reuse its `parse_args`, `default_branch`, `active_worktree_branches`, `is_protected_branch`, `repo_slug` and `print_candidate` shapes (L46-216);
  - options: `--repo PATH`, `--remote NAME`, `--branch NAME` (single-branch), `--apply`, `-h`;
  - dry-run by default.
- `NEW: .agents/scripts/tests/test-local-branch-cleanup-helper.sh` — model on `.agents/scripts/tests/test-remote-branch-cleanup-helper.sh`: its `setup_repo`, `make_branch`, `merge_branch_to_main` and `install_gh_stub` fixtures and the `AIDEVOPS_REMOTE_BRANCH_CLEANUP_SKIP_GH` switch pattern (use `AIDEVOPS_LOCAL_BRANCH_CLEANUP_SKIP_GH`).
- `EDIT: .agents/scripts/worktree-helper-cmds.sh:334-352` — in `_remove_finalize_post_removal`, when `removed_branch` is non-empty, call the helper with `--repo <canonical> --branch <removed_branch> --apply` as a best-effort step. A refusal prints `branch preserved: <reason>` and returns 0.
- `EDIT: .agents/scripts/worktree-clean-lib.sh:1591-1594` — replace the raw `git branch -D` with the same single-branch helper call, keeping `localdev_auto_branch_rm`.
- `EDIT: aidevops.sh:2010-2033` — add `local-branches` to `_main_dispatch_cleanup` via `_dispatch_helper "local-branch-cleanup-helper.sh"`, and extend the help text.
- `EDIT: .agents/workflows/worktree-cleanup.md:134-144` — add a "Local Branch Cleanup" subsection next to the remote-branch one.
- `EDIT: .agents/scripts/audit-log-helper.sh` — required adjacent integration: register `local-branch-delete` in the audit event allowlist; the requested `audit-log-helper.sh log local-branch-delete` currently rejects the event as invalid. Verify via `test-local-branch-cleanup-helper.sh` and audit validation.

### Complete Write Surface

- **Callers/readers:** `cmd_remove` in `.agents/scripts/worktree-helper-cmds.sh:452-498` via `_remove_finalize_post_removal`; the removal path in `.agents/scripts/worktree-clean-lib.sh:1591-1594` used by `worktree-helper.sh clean` and pulse cleanup; `_main_dispatch_cleanup` in `aidevops.sh`; operators reading `.agents/workflows/worktree-cleanup.md`.
- **Writers/mutation paths:** the only ref mutation is `git update-ref -d refs/heads/<branch> <scanned_sha>`, run from a transport created by `git worktree add --detach --no-checkout` in the new `.agents/scripts/local-branch-cleanup-helper.sh`. Each deletion is recorded with `.agents/scripts/audit-log-helper.sh log local-branch-delete`. The transport is removed with `git worktree remove --force`, which the guard allows for linked worktrees.
- **Schemas/config:** one new optional test/offline env, `AIDEVOPS_LOCAL_BRANCH_CLEANUP_SKIP_GH`, documented in the usage text of `.agents/scripts/local-branch-cleanup-helper.sh`. The guard policy in `.agents/scripts/canonical_git_policy.py` is unchanged.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/local-branch-cleanup-helper.sh` and the edited scripts to `~/.aidevops/agents/scripts/`. `aidevops.sh` is the installed CLI.
- **Migrations/backfills:** N/A because there is no persisted format. Existing orphaned branches are handled by running `aidevops cleanup local-branches --apply` once.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/local-branch-cleanup-helper.sh`, `.agents/scripts/worktree-helper-cmds.sh`, `.agents/scripts/worktree-clean-lib.sh` and `aidevops.sh`. Deleted branches are restored with `git branch <branch> <sha>` from the audit-log line while their objects exist.
- **Existing verification/tests:** `.agents/scripts/tests/test-remote-branch-cleanup-helper.sh`, `.agents/scripts/tests/test-canonical-git-command-guard.sh`, `.agents/scripts/tests/test-worktree-cleanup-branch-merged-owned-skip.sh`, plus the new `.agents/scripts/tests/test-local-branch-cleanup-helper.sh`.

### Implementation Steps

1. Write the scan in `.agents/scripts/local-branch-cleanup-helper.sh`. A branch is a candidate when it:
   - is a local `refs/heads/*` branch, not protected, not checked out in any worktree, and has no open PR;
   - is merged when its tip is an ancestor of `<remote>/<default>`. Only otherwise, it is merged when its tip equals the `head.sha` of a closed PR with `merged_at` set and a matching `head.ref`, using one bounded `gh api` query per branch.

   Report every other branch as `keep <reason>`.
2. Implement `--apply` with one `--detach --no-checkout` transport per run and `update-ref -d` with the scanned SHA as a lease. On failure, report `failed <branch> ref changed after scan`.
   - Log `deleted <branch> <sha>`, then call `.agents/scripts/audit-log-helper.sh log local-branch-delete`.
   - Always remove the transport, including on error, using a trap.
3. Wire single-branch mode into `.agents/scripts/worktree-helper-cmds.sh` and `.agents/scripts/worktree-clean-lib.sh`, and the CLI into `aidevops.sh`.
4. Write the new test and the docs subsection, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** another session may commit to or check out a branch between scan and delete; `update-ref -d <ref> <scanned_sha>` fails atomically if the ref moved, and checked-out branches are re-read right before deletion; the transport path is unique per run, as `.agents/scripts/remote-branch-cleanup-helper.sh:229-247` does.
- **Migration/rollback:** no persisted format; rollback is a revert, and each deleted branch is restorable from its logged SHA.
- **Mixed-version/backward compatibility:** when the helper is missing (older deployment), `remove` and `clean` skip branch deletion and behave exactly as today; the canonical guard allowlist is unchanged, so no other caller gains mutation rights.
- **Idempotency/retry:** a branch that is already absent reports `absent` and succeeds, and rerunning `--apply` deletes nothing new.
- **Partial failure/recovery:** a `gh` error or timeout never makes a branch deletable (squash-merge evidence is required, otherwise `keep github evidence unavailable`); if the transport cannot be created, nothing is deleted and the helper exits non-zero in bulk mode but returns 0 with `branch preserved` in single-branch mode, so worktree removal never fails because of branch cleanup.

### Complexity Impact

- **Target function:** `_remove_finalize_post_removal` in `.agents/scripts/worktree-helper-cmds.sh`
- **Current line count:** about 19 lines (L334-352; threshold: 100 lines for function-complexity)
- **Estimated growth:** about +4 lines, for one guarded helper call
- **Projected post-change:** about 23 lines (23% of threshold). The `.agents/scripts/worktree-clean-lib.sh` change replaces one line with one call.
- **Action required:** keep all scan and delete logic in the new helper, with functions under 60 lines each.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/local-branch-cleanup-helper.sh .agents/scripts/worktree-helper-cmds.sh .agents/scripts/worktree-clean-lib.sh aidevops.sh
bash .agents/scripts/tests/test-local-branch-cleanup-helper.sh
bash .agents/scripts/tests/test-remote-branch-cleanup-helper.sh
bash .agents/scripts/tests/test-canonical-git-command-guard.sh
bash .agents/scripts/tests/test-worktree-cleanup-branch-merged-owned-skip.sh
```

- **Surface mapping:** `shellcheck` covers all four changed scripts; `test-local-branch-cleanup-helper.sh` proves ancestor and squash-merge deletion, dry-run immutability, the keep cases (protected, checked out, open PR, unmerged local commits, missing GitHub evidence), the moved-ref lease failure (concurrency hazard), rerun idempotency and transport removal on error (partial-failure hazard); `test-remote-branch-cleanup-helper.sh` proves the reused remote patterns are unchanged; `test-canonical-git-command-guard.sh` proves the guard policy is unchanged (mixed-version hazard); `test-worktree-cleanup-branch-merged-owned-skip.sh` proves that `clean` still skips branches owned by other sessions.
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:**

- Do not add `branch` deletion, `update-ref` or any other mutation to `.agents/scripts/canonical_git_policy.py` or `.agents/scripts/canonical_git_readonly.py`.
- Do not use `git branch -D` or delete without the `update-ref` SHA lease.
- Do not delete branches on name-only PR evidence; the tip SHA must match.
- Do not make worktree removal fail because branch cleanup failed.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/local-branch-cleanup-helper.sh`
- `.agents/scripts/tests/test-local-branch-cleanup-helper.sh`
- `.agents/scripts/worktree-helper-cmds.sh`
- `.agents/scripts/worktree-clean-lib.sh`
- `aidevops.sh`
- `.agents/workflows/worktree-cleanup.md`
- `TODO.md`

## Acceptance Criteria

- [ ] `aidevops cleanup local-branches --apply` deletes local branches that are ancestors of the default branch or whose tip equals a merged PR's head SHA, prints `deleted <branch> <sha>` for each, and writes an audit-log entry.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-local-branch-cleanup-helper.sh"
  ```

- [ ] `worktree-helper.sh remove` and `clean` delete the removed worktree's branch through the helper when it is merged, and print `branch preserved: <reason>` otherwise.

  ```yaml
  verify:
    method: codebase
    pattern: "local-branch-cleanup-helper.sh"
    path: ".agents/scripts/worktree-helper-cmds.sh"
  ```

- [ ] Negative/regression:
  - never deletes protected, checked-out, open-PR or unmerged-local-commit branches, or branches with unavailable GitHub evidence;
  - a moved ref is reported as `failed` and is not deleted;
  - dry-run changes no refs;
  - guard policy tests and remote-branch cleanup tests pass unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-local-branch-cleanup-helper.sh && bash .agents/scripts/tests/test-remote-branch-cleanup-helper.sh && bash .agents/scripts/tests/test-canonical-git-command-guard.sh && bash .agents/scripts/tests/test-worktree-cleanup-branch-merged-owned-skip.sh"
  ```

## Context & Decisions

- A dedicated audited helper was chosen over allowlisting `git branch -d` in the canonical guard, which keeps the invariant that canonical mutations go through audited helpers. Linked worktrees already create and advance shared refs, so a linked-worktree transport with a SHA lease matches the existing remote-cleanup precedent.
- `update-ref -d` with the scanned SHA was chosen over `git branch -d`, because it is atomic against concurrent moves and does not depend on the transport's `HEAD` for merge checks.

## Relevant Files

- `.agents/scripts/remote-branch-cleanup-helper.sh:46-254` — reference pattern (argument parsing, protected list, PR lookup, transport)
- `.agents/scripts/tests/test-remote-branch-cleanup-helper.sh:64-178` — fixture pattern
- `.agents/scripts/worktree-helper-cmds.sh:334-352,354-447` — manual removal finalise
- `.agents/scripts/worktree-clean-lib.sh:1591-1594` — `clean` branch deletion
- `.agents/scripts/canonical_git_readonly.py:13-42` — branch mutation classification (read-only)
- `aidevops.sh:2010-2033` — cleanup CLI dispatch
- `.agents/workflows/worktree-cleanup.md:128-144` — cleanup docs

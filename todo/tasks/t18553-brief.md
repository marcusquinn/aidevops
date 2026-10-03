<!-- aidevops:brief-schema=v2 -->

# t18553: Claim task ID: keep depth-1 counter fetches in the isolated context so linked-worktree claims stop truncating shared repo history

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** While publishing a planning brief, an interactive session's pre-edit check reported that the aidevops clone was shallow. `.git/shallow` in the shared store listed the tip of `origin/main` and a counter-branch claim commit, and `git merge-base origin/main <branch created earlier that day>` returned nothing. A scratch repro showed that a `--depth=1` fetch in a linked worktree makes the parent clone shallow. The claim path has three such fetches. Following ambient-capture policy, the session filed this as GH#33033 for auto-dispatch.

## What

`claim-task-id-counter.sh` passes `--depth=1` only when the fetch runs inside its isolated bare Git context. Claims from linked worktrees or unmanaged repos fetch normally, so they never write shallow grafts into the shared `.git/shallow`. Existing shallow stores then heal through the documented `fetch --unshallow` path, and a claim never re-truncates them.

## Why

- `_claim_counter_prepare_git_context` (`.agents/scripts/claim-task-id-counter.sh:211-287`) creates an isolated bare repo only when the path is classified `canonical`. Otherwise it sets `CAS_GIT_CONTEXT_PATH` to the repo path itself (L221-237), which is the shared store for a linked worktree.
- `_run_git_with_ssh_fallback` (L353-412) runs `git -C "$CAS_GIT_CONTEXT_PATH" fetch ...` in that context.
- Three fetches use `--depth=1`:
  - L499-501, the implicit dedicated counter-branch fetch, added by PR #32963 on 2026-09-29;
  - L520-522, the implicit default-branch validation fetch, also from PR #32963;
  - L1126-1127, `read_remote_counter`, which is older. When the counter branch is `main` it truncates main.
- Git keeps `shallow` in the common dir shared by all worktrees. A depth fetch in one worktree therefore truncates `origin/main` for the canonical checkout and every other worktree.
- Consequences:
  - `merge-base` with older branches fails;
  - rebases cascade into add/add conflicts (`.agents/reference/git-hygiene.md`, "Shallow Clone — add/add Conflict Cascade");
  - `.agents/scripts/full-loop-helper-commit.sh` runs a full-history `fetch --unshallow` before each worker rebase;
  - `.agents/scripts/pre-edit-check.sh` warns in every worktree.
- Evidence from 2026-09-29: the canonical aidevops `.git/shallow` (mtime 13:18:06Z) lists `3c4b9a739e` (the `origin/main` tip) and `f67aa30dd8` (`chore: claim t18550`). A scratch clone with 3 commits went from `is-shallow-repository=false` to `true`, and `rev-list --count main` from 3 to 1, after one `fetch --depth=1 --no-tags origin +refs/heads/main:refs/remotes/origin/main` in its linked worktree.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: a narrowly specified gate on three call sites in one script, plus fixture changes in an existing test. Not `tier:simple`, because the Git shallow semantics, the Bash 3.2 `set -u` empty-array hazard, and the test fixture's vacuous-pass trap each need judgement.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/claim-task-id-counter.sh:166-182,496-501,520-522,1126-1127`:
  - Add `_counter_context_is_isolated` next to `_counter_git` / `_counter_source_git`. It returns 0 only when `_CLAIM_COUNTER_CONTEXT_ROOT` is non-empty and `CAS_GIT_CONTEXT_PATH` equals `${_CLAIM_COUNTER_CONTEXT_ROOT}/repository.git`, and 1 otherwise, including after `_claim_counter_cleanup_git_context` (L192-209).
  - At the three depth fetches, pass `--depth=1` only when the gate succeeds; keep every other argument unchanged.
  - Rewrite the L496-498 comment to explain the shared-shallow-file reason.
- `EDIT: .agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh:36-84,262-308,475-512`:
  - Model on `test_implicit_dedicated_counter_branch` (L262-308) and its `setup_protected_remote` fixture (L36-84), which already clones through a `file://` `insteadOf` URL (so `--depth` is honoured) and adds a linked worktree at L80.
  - Seed at least two commits on `main` before the counter commit.
  - Add two linked-worktree cases, one with `{"counter_branch":"main"}` and one with `{}`. Each asserts that `git -C "${tmpdir}/seed" rev-parse --is-shallow-repository` prints `false` and that `git -C "${tmpdir}/seed" rev-list --count origin/main` is at least `2` after the claim.
  - Register both cases in `main` (L475-512).
- `EDIT: .agents/reference/git-hygiene.md:11-60`: in "Shallow Clone — add/add Conflict Cascade", add a short "Known cause" note:
  - task-ID claims from linked worktrees used to cause this (GH#33033);
  - recover with `git fetch --unshallow origin` from any linked worktree, never from the canonical checkout;
  - the shared store heals every worktree at once.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/claim-task-id.sh:1760-1762` calls `_claim_counter_prepare_git_context` and `resolve_implicit_counter_branch`; `.agents/scripts/claim-task-id.sh:1031` calls `read_remote_counter`; every worker, interactive session and planning helper that claims IDs (for example `.agents/scripts/new-task-helper.sh`) reaches these through `claim-task-id.sh`.
- **Writers/mutation paths:** the only persistent effect changed is the Git shallow file and remote-tracking refs written by `fetch` at `.agents/scripts/claim-task-id-counter.sh:499-501,520-522,1126-1127`. The CAS push and counter commit paths are not modified.
- **Schemas/config:** N/A because no config keys, env tunables or file formats change. `.aidevops.json` `counter_branch` semantics stay the same.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/claim-task-id-counter.sh` to `~/.aidevops/agents/scripts/`; workers use the deployed copy after release.
- **Migrations/backfills:** N/A because the fix is forward-only. Already-shallow stores are repaired by the existing auto-unshallow in `.agents/scripts/full-loop-helper-commit.sh` or by the documented manual `git fetch --unshallow origin` from a linked worktree; this task must not add unshallowing to the claim path.
- **Cleanup/rollback paths:** revert the PR touching `.agents/scripts/claim-task-id-counter.sh`; behaviour returns to the current depth fetches with no persisted state to undo.
- **Existing verification/tests:** `.agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh`, `.agents/scripts/tests/test-claim-task-id-https-ssh-fallback.sh`, `.agents/scripts/tests/test-claim-task-id-concurrent-cas.sh`, `.agents/scripts/tests/test-claim-task-id-wall-timeout.sh`, `.agents/scripts/tests/test-claim-task-id.sh`.

### Implementation Steps

1. Add `_counter_context_is_isolated` with an explicit `return 0` / `return 1`.
2. At each depth fetch, build the args without an empty-array expansion under `set -u`. Either use two explicit `_run_git_with_ssh_fallback` invocations in an `if`/`else`, or `local -a depth_args=()` with `${depth_args[@]+"${depth_args[@]}"}`.
3. Update the L496-498 comment.
4. Extend the test fixture and cases, and confirm the new cases fail on the unfixed script before the fix, and pass after it.
5. Add the git-hygiene note and run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** CAS ordering is unchanged. Removing `--depth` in the shared context only makes the fetch incremental against objects already present, so it cannot race the counter push.
- **Migration/rollback:** no persisted format. Rollback is a revert, and existing shallow stores behave exactly as today.
- **Mixed-version/backward compatibility:**
  - Older deployed copies keep truncating until updated, and the fix never re-deepens anything itself. The existing `.agents/scripts/full-loop-helper-commit.sh` auto-unshallow still handles leftovers.
  - `claim-task-id.sh` runs under `set -euo pipefail`, so on Bash 3.2 `"${arr[@]}"` on an empty array aborts with `unbound variable`. Use the guarded expansion or explicit branches (`reference/bash-compat.md`).
- **Idempotency/retry:** a repeated claim in a linked worktree performs a normal incremental fetch and leaves `.git/shallow` absent or unchanged. SSH fallback retries use the same argument set.
- **Partial failure/recovery:** fetch failure handling (`COUNTER_BRANCH_DISCOVERY_ERROR`, `ls-remote` probe, `Failed to fetch` warning) is unchanged. If the gate itself cannot decide, it returns 1 (no depth), which is the safe direction for the shared store.

### Complexity Impact

- **Target function:** `resolve_implicit_counter_branch` in `.agents/scripts/claim-task-id-counter.sh`
- **Current line count:** about 60 lines (L483-545; threshold: 100 lines for function-complexity)
- **Estimated growth:** about +8 lines for two gated fetch invocations
- **Projected post-change:** about 68 lines (68% of threshold); `read_remote_counter` grows by about 4 lines
- **Action required:** keep the gate in the one new helper, and do not duplicate the isolated-context predicate at call sites.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/claim-task-id-counter.sh .agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh
bash .agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh
bash .agents/scripts/tests/test-claim-task-id-https-ssh-fallback.sh
bash .agents/scripts/tests/test-claim-task-id-concurrent-cas.sh
bash .agents/scripts/tests/test-claim-task-id-wall-timeout.sh
bash .agents/scripts/tests/test-claim-task-id.sh
```

- **Surface mapping:**
  - `shellcheck` covers both changed scripts.
  - `test-claim-task-id-protected-counter-branch.sh` covers the new linked-worktree non-shallow cases, the existing canonical isolated-context discovery (which keeps `--depth=1`), and the dedicated-branch selection.
  - `test-claim-task-id-https-ssh-fallback.sh` proves the fallback retry still passes the same arguments (partial-failure hazard).
  - `test-claim-task-id-concurrent-cas.sh` proves CAS ordering is unchanged (concurrency hazard).
  - `test-claim-task-id-wall-timeout.sh` proves the timeouts are unchanged.
  - `test-claim-task-id.sh` proves end-to-end ID allocation (mixed-version hazard).
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:**

- Do not add `fetch --unshallow`, `--deepen` or any history-wide fetch to the claim path; it runs inside 30s CAS timeouts.
- Do not remove `--depth=1` from the isolated bare context; PR #32963's bounded discovery must stay.
- Do not change `.agents/scripts/canonical_git_policy.py` or `.agents/scripts/canonical-write-policy-helper.py`.
- Any new `--depth` added elsewhere in this file (for example by GH#32692 / t18497) must use the same `_counter_context_is_isolated` gate.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/claim-task-id-counter.sh`
- `.agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh`
- `.agents/reference/git-hygiene.md`
- `TODO.md`

## Acceptance Criteria

- [ ] A claim with `--repo-path <linked worktree>` leaves the parent repository non-shallow, both with an explicit `main` counter branch and with implicit dedicated-branch discovery.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh"
  ```

- [ ] Depth-1 fetches are gated by the isolated-context predicate.

  ```yaml
  verify:
    method: codebase
    pattern: "_counter_context_is_isolated"
    path: ".agents/scripts/claim-task-id-counter.sh"
  ```

- [ ] Negative/regression:
  - canonical claims still use the isolated bare context with `--depth=1`;
  - SSH fallback, CAS ordering and wall-timeout behaviour are unchanged;
  - no unshallow or history-wide fetch is added to the claim path.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-claim-task-id-https-ssh-fallback.sh && bash .agents/scripts/tests/test-claim-task-id-concurrent-cas.sh && bash .agents/scripts/tests/test-claim-task-id-wall-timeout.sh && bash .agents/scripts/tests/test-claim-task-id.sh"
  ```

- [ ] Changed-file lint is clean: `shellcheck .agents/scripts/claim-task-id-counter.sh .agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh`

## Context & Decisions

- The depth is gated on the isolated context, not on whether the repo is already shallow. The isolated bare repo is the only context where depth saves transfer: it has no object reuse. In a shared store a normal fetch is already incremental.
- The fix is forward-only, and unshallowing stays with the existing commit-and-PR path. Adding a history-wide fetch inside the claim's 30s CAS timeout would trade a correctness bug for a timeout bug (compare GH#32953).
- Fixture seeding needs two or more commits: `--depth=1` on a root-only history writes no graft, so a single-commit fixture would pass without exercising the bug.

## Relevant Files

- `.agents/scripts/claim-task-id-counter.sh:166-287` — Git context helpers and isolated-context setup
- `.agents/scripts/claim-task-id-counter.sh:353-412` — `_run_git_with_ssh_fallback`
- `.agents/scripts/claim-task-id-counter.sh:483-545,1121-1140` — the three depth fetches
- `.agents/scripts/claim-task-id.sh:1031,1760-1762` — callers
- `.agents/scripts/tests/test-claim-task-id-protected-counter-branch.sh:36-84,262-308` — fixture and reference test
- `.agents/reference/git-hygiene.md:11-100` — shallow-clone guidance

<!-- aidevops:brief-schema=v2 -->

# t18550: Full-loop merge: sync canonical through the audited fast-forward and reconcile planning after it, not before

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Found during the pulse-review follow-up publication. Every interactive merge (#33002, #33005, #33008, #33010) needed a manual canonical fast-forward and a manual planning reconcile. Running the canonical Git guard on the helper's fetch argv showed that the guard denies it. Issue: GH#33013.

## What

An interactive `full-loop-helper.sh merge` should leave a clean canonical checkout at the merge SHA, using the audited `canonical-recovery-helper.sh fast-forward-current` path, and then reconcile planning publication in the same command. Headless sessions keep today's no-mutation reporting. Refusals report their real cause.

## Why

- `.agents/scripts/full-loop-helper-merge.sh:1824` runs `git -C "$canonical_dir" fetch --quiet origin "$default_branch" >/dev/null 2>&1`. The runtime `git` shim routes this through `.agents/scripts/canonical_git_policy.py:240-276`, which returns `canonical worktree mutation via 'git fetch'`. The helper hides the denial and prints `CANONICAL_SYNC_PENDING=true reason=origin_fetch_failed`.
- `cmd_merge` reconciles planning (L2259) before it reports or syncs canonical (L2261). `.agents/scripts/planning-publication-reconcile.sh:287-290` then always refuses with `HEAD is not exact origin/main SHA`.
- The result is two manual commands per interactive planning merge, and `publication:pending` issues wait for the pulse reconcile (`.agents/scripts/pulse-issue-reconcile.sh:1268`) or an operator.
- Precedent: `aidevops update` already calls the audited fast-forward automatically, with a clean-state check and a `sync-mirror` fallback (`.agents/scripts/aidevops-cli/aidevops-update-lib.sh:79-104`).

## Tier

**Selected tier:** `tier:thinking`

`tier:thinking`: it changes when an automated path mutates the canonical checkout. The worker must keep the canonical-guard invariant (no direct canonical Git mutation), separate interactive from headless authority, and preserve an existing no-mutation test.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/full-loop-helper-merge.sh:1819-1869` — in `_merge_refresh_canonical_for_cleanup` and `_merge_report_canonical_sync_state`:
  - read state only through `AIDEVOPS_REAL_GIT_BIN`/real-git read commands;
  - for interactive sessions (`! _merge_is_headless_session`, L218-221), when canonical is clean, on the default branch and fast-forwardable, call `canonical-recovery-helper.sh fast-forward-current --repo <canonical> --branch <default> --issue <N> --confirm FAST_FORWARD_CANONICAL_BRANCH` with `AIDEVOPS_REAL_GIT_BIN` set, as in `.agents/scripts/aidevops-cli/aidevops-update-lib.sh:94-99`;
  - print `LIFECYCLE_STATE=CANONICAL_SYNCED` on success;
  - otherwise, and always when headless or when `AIDEVOPS_MERGE_CANONICAL_FAST_FORWARD=0`, keep `CANONICAL_SYNC_PENDING` plus `CANONICAL_SYNC_NEXT`;
  - capture helper or guard stderr and report `reason=canonical_guard_denied` or `reason=fast_forward_refused` instead of `origin_fetch_failed`.
- `EDIT: .agents/scripts/full-loop-helper-merge.sh:2258-2261` — run `_merge_report_canonical_sync_state` before `_merge_reconcile_planning_publication`. When canonical is still pending, skip reconcile and print `PLANNING_RECONCILE_NEXT=planning-publication-reconcile.sh reconcile --repo <slug> --sha <merge_sha>`.
- `EDIT: .agents/scripts/full-loop-helper-merge.sh:1685-1709` — let `_merge_reconcile_planning_publication` accept a canonical-synced flag, so the skip path is explicit rather than a failed reconcile.
- `EDIT: .agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh:720-757` — keep `test_refresh_canonical_reports_pending_without_mutation` for the headless and opt-out cases, and add interactive fast-forward, dirty-canonical refusal and diverged-canonical refusal cases using the same bare-origin fixture with a stub recovery helper.
- `EDIT: .agents/scripts/tests/test-full-loop-merge.sh:471` — update the `_merge_report_canonical_sync_state` stub users for the new call order and add a case asserting that reconcile runs only after a synced state.

### Complete Write Surface

- **Callers/readers:** `cmd_merge` in `.agents/scripts/full-loop-helper-merge.sh:2258-2265` and `_merge_cleanup_linked_worktree` at `.agents/scripts/full-loop-helper-merge.sh:1909` call the refresh; operators and `.agents/workflows/full-loop.md` read `LIFECYCLE_STATE`, `CANONICAL_SYNC_PENDING`, `CANONICAL_SYNC_NEXT` and the new `PLANNING_RECONCILE_NEXT` lines.
- **Writers/mutation paths:** the only canonical mutation is the delegated `.agents/scripts/canonical-recovery-helper.sh` `fast-forward-current` call, which keeps its own audit log; `.agents/scripts/planning-publication-reconcile.sh` writes issue labels exactly as today.
- **Schemas/config:** one new optional env `AIDEVOPS_MERGE_CANONICAL_FAST_FORWARD` (default on for interactive sessions), documented beside `_merge_refresh_canonical_for_cleanup` in `.agents/scripts/full-loop-helper-merge.sh`; output keys stay backward compatible, with the added `PLANNING_RECONCILE_NEXT`.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/full-loop-helper-merge.sh` to `~/.aidevops/agents/scripts/` and the runtime bundle on release.
- **Migrations/backfills:** N/A because no persisted state format changes; canonical checkouts left behind by earlier merges converge on the next merge or `aidevops update`.
- **Cleanup/rollback paths:** set `AIDEVOPS_MERGE_CANONICAL_FAST_FORWARD=0` to restore report-only behaviour, or revert the PR touching `.agents/scripts/full-loop-helper-merge.sh` and its two test files.
- **Existing verification/tests:** `.agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh`, `.agents/scripts/tests/test-full-loop-merge.sh`, `.agents/scripts/tests/test-canonical-recovery-helper.sh`, `.agents/scripts/tests/test-canonical-git-command-guard.sh`.

### Implementation Steps

1. Extract a small helper in `.agents/scripts/full-loop-helper-merge.sh` that decides whether canonical is eligible for the audited fast-forward (interactive, not opted out, clean, on the default branch, HEAD an ancestor of the merge SHA read through real git) and runs `.agents/scripts/canonical-recovery-helper.sh fast-forward-current`.
2. Rewrite `_merge_refresh_canonical_for_cleanup` to use that helper, drop the direct canonical fetch, and map captured stderr to precise reasons.
3. Reorder `cmd_merge` so canonical sync precedes planning reconcile, and add the explicit skip with `PLANNING_RECONCILE_NEXT`.
4. Extend the two test files, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** the pulse or another session may be converging canonical at the same time; `.agents/scripts/canonical-recovery-helper.sh` re-validates cleanliness and ancestry under its own checks and refuses if state changed, and the merge helper must treat a refusal as `CANONICAL_SYNC_PENDING`, never retry with force.
- **Migration/rollback:** no persisted-format change; the opt-out env restores report-only behaviour without a release, and a revert restores it fully.
- **Mixed-version/backward compatibility:** older deployed recovery helpers without `fast-forward-current` must be detected (non-zero plus usage output) and fall back to today's `CANONICAL_SYNC_NEXT` output; existing output keys and the headless no-mutation behaviour stay unchanged.
- **Idempotency/retry:** when canonical already equals the merge SHA the eligibility helper returns synced without calling the recovery helper, so the second call from `_merge_cleanup_linked_worktree` and repeated merges are no-ops; reconcile is already idempotent.
- **Partial failure/recovery:** if the fast-forward succeeds but reconcile fails, the helper prints `PLANNING_RECONCILE_NEXT` and still exits 0 for the merge, as today; if the fast-forward fails, nothing in canonical changed and the operator gets the exact `CANONICAL_SYNC_NEXT` command.

### Complexity Impact

- **Target function:** `_merge_refresh_canonical_for_cleanup` in `.agents/scripts/full-loop-helper-merge.sh`
- **Current line count:** about 21 lines (L1819-1840; threshold: 100 lines for function-complexity)
- **Estimated growth:** about +10 lines, with the eligibility and recovery call extracted into a new helper under 40 lines
- **Projected post-change:** about 31 lines (31% of threshold). `cmd_merge` must only reorder two existing calls and pass one flag.
- **Action required:** keep new logic in the extracted helper and do not add branches to `cmd_merge`.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/full-loop-helper-merge.sh
bash .agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh
bash .agents/scripts/tests/test-full-loop-merge.sh
bash .agents/scripts/tests/test-canonical-recovery-helper.sh
bash .agents/scripts/tests/test-canonical-git-command-guard.sh
```

- **Surface mapping:** `shellcheck` covers the changed script; `test-full-loop-merge-worktree-cleanup.sh` proves the interactive fast-forward, the headless, opt-out, dirty and diverged no-mutation cases (concurrency and partial-failure hazards) and the second-call no-op (idempotency hazard); `test-full-loop-merge.sh` proves the new sync-before-reconcile order and the `PLANNING_RECONCILE_NEXT` skip; `test-canonical-recovery-helper.sh` and `test-canonical-git-command-guard.sh` prove that the audited path and the guard policy are unchanged (mixed-version and rollback hazards).
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:**

- Do not add `fetch` or any other mutation to the canonical guard allowlist in `.agents/scripts/canonical_git_policy.py`.
- Do not run direct `git fetch`, `git merge`, `git reset` or `git pull` in canonical from `.agents/scripts/full-loop-helper-merge.sh`.
- Do not fast-forward canonical from headless sessions.
- Do not change `.agents/scripts/canonical-recovery-helper.sh` or `.agents/scripts/planning-publication-reconcile.sh`.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/full-loop-helper-merge.sh`
- `.agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh`
- `.agents/scripts/tests/test-full-loop-merge.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] In an interactive session with a clean canonical on its default branch, merge fast-forwards canonical through the recovery helper, prints `LIFECYCLE_STATE=CANONICAL_SYNCED`, and then runs planning reconcile in the same command.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh && bash .agents/scripts/tests/test-full-loop-merge.sh"
  ```

- [ ] A refused sync reports `reason=canonical_guard_denied` or `reason=fast_forward_refused`, and prints `CANONICAL_SYNC_NEXT` plus `PLANNING_RECONCILE_NEXT`.

  ```yaml
  verify:
    method: codebase
    pattern: "PLANNING_RECONCILE_NEXT"
    path: ".agents/scripts/full-loop-helper-merge.sh"
  ```

- [ ] Negative/regression:
  - headless sessions, `AIDEVOPS_MERGE_CANONICAL_FAST_FORWARD=0`, and dirty, diverged or non-default-branch canonicals are never mutated;
  - `canonical drift is explicit pending without unaudited mutation` still passes;
  - the guard policy and recovery helper tests pass unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-canonical-recovery-helper.sh && bash .agents/scripts/tests/test-canonical-git-command-guard.sh && bash .agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh"
  ```

- [ ] After release, an interactive planning-PR merge moves its `publication:pending` issue to `auto-dispatch` without manual commands. This is observed after deploy, not in this PR.

## Context & Decisions

- The audited recovery helper was chosen over allowlisting `fetch` in the guard. The guard's invariant is that canonical mutations go through audited helpers, and `aidevops update` already follows this pattern.
- Full-loop ownership already includes safely syncing the local PR base for interactive sessions (`.agents/AGENTS.md` "Task and completion discipline"). The merge command is therefore sufficient authority for a clean, audited fast-forward; headless workers do not own canonical.

## Relevant Files

- `.agents/scripts/full-loop-helper-merge.sh:218-221` — `_merge_is_headless_session`
- `.agents/scripts/full-loop-helper-merge.sh:1685-1709` — planning reconcile call
- `.agents/scripts/full-loop-helper-merge.sh:1819-1869` — canonical refresh and sync report
- `.agents/scripts/full-loop-helper-merge.sh:2258-2265` — post-merge call order
- `.agents/scripts/canonical_git_policy.py:240-276` — guard classification (read-only)
- `.agents/scripts/canonical-recovery-helper.sh:737-794` — `fast-forward-current` entry checks (read-only)
- `.agents/scripts/aidevops-cli/aidevops-update-lib.sh:79-104` — audited fast-forward precedent
- `.agents/scripts/planning-publication-reconcile.sh:271-290` — exact-SHA precondition (read-only)

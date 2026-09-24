<!-- aidevops:brief-schema=v2 -->

# t18476: Initialize CI privacy context during planning publication reconciliation

## Pre-flight

- [x] Memory recall: `planning-publication-reconcile issue-sync push default branch publication pending auto-dispatch workflow failure` → 0 relevant memories.
- [x] Discovery pass: recent issue-sync commits touch artifact retention and permissions; no matching open issue or PR in searches for planning publication, privacy, CI inventory or `repos.json`. Verify again before editing.
- [x] File refs verified: `.github/workflows/issue-sync-reusable.yml:259-305`, `.agents/scripts/issue-sync-helper.sh:67-69`, `.agents/scripts/issue-sync-ci-context.sh:12-62`, `.agents/scripts/planning-publication-reconcile.sh:8-24,218-245`, `.agents/scripts/tests/test-issue-sync-ci-context.sh:24-120`, and `.agents/scripts/tests/test-planning-publication-reconcile.sh:20-74` at `a1a0c1bb8`.
- [x] Tier: `tier:standard` — reuse the existing repository-scoped inventory contract across a process boundary; verify privacy and fail-closed behavior, not just a line-order assertion.
- [x] Seeded draft PR: skipped — no patch prepared; reproduce the hosted job failure first, then use the existing CI-context helper as the reference.

## Origin

- **Created:** 2026-09-24
- **Session:** OpenCode interactive, while verifying the publication of an independent security issue.
- **Created by:** AI interactive; evidenced follow-up from a failed GitHub Actions run.
- **Conversation context:** The user requested an auto-dispatchable issue for a separate Pulse trust boundary. Publishing that issue exposed a framework regression: the CI task-publication transition stays pending until a local, exact-SHA manual reconciliation.

## What

Make the Issue Sync job's `Reconcile pending planning publication` step use a repository-scoped privacy and write-policy inventory in GitHub Actions, without a local `repos.json`. Preserve exact-default-SHA/ref/brief validation and fail-closed behavior: an unverified snapshot or missing/invalid CI identity must leave `publication:pending` intact. A valid planning PR merge should progress a ready issue to its intended dispatch status automatically.

## Why

In Issue Sync run `36072119531`, the merge of planning PR #32338 passed `Close issues` and `Push new tasks`, then `Reconcile pending planning publication` failed because the runner's local `repos.json` was absent: `[privacy-guard][BLOCK] Private entity inventory could not be loaded`. The issue remained `publication:pending` until exact-SHA reconciliation in a linked local worktree. `issue-sync-helper.sh:67-69` prepares ephemeral CI context *inside its own process*; it does not persist those environment exports for the following workflow step running `planning-publication-reconcile.sh`. The latter sources GitHub write wrappers but does not initialize the inventory. This is a publication failure, not evidence that the privacy guard should be weakened.

## Tier

**Selected tier:** `tier:standard`. The existing helper and earlier workflow shim setup define a narrow, reversible pattern; choose the minimal safe integration and test the cross-process behavior. Do not broaden repository write permissions or disable the privacy guard.

## How (Approach)

### Progressive Context Plan

- **Read first:** the publication step in `.github/workflows/issue-sync-reusable.yml:259-339`, the CI inventory setup in `.agents/scripts/issue-sync-ci-context.sh:12-62`, the initialization order in `.agents/scripts/issue-sync-helper.sh:60-72`, and `planning-publication-reconcile.sh:8-24,218-245`.
- **Load if needed:** `.agents/scripts/shared-gh-wrappers.sh` and `privacy-guard-helper.sh` when checking when the write wrapper resolves inventory; existing CI-context and publication test fixtures for regression coverage.
- **Stop when:** the same CI step can reconcile a valid exact-main snapshot with only the current repository inventory, and invalid context still fails before clearing `publication:pending`.

### Files to Modify

- EDIT: `.agents/scripts/planning-publication-reconcile.sh` — establish the existing CI-scoped context before the write wrappers are used, or adopt an equivalent explicit workflow step to persist the same scoped environment.
- EDIT (conditional): `.github/workflows/issue-sync-reusable.yml` — if the chosen fix propagates the inventory via `$GITHUB_ENV` between shell steps; keep the privacy guard enabled.
- EDIT: `.agents/scripts/tests/test-issue-sync-ci-context.sh` and/or `.agents/scripts/tests/test-planning-publication-reconcile.sh` — cover actual reconciler initialization with `GITHUB_ACTIONS=true`, no home `repos.json`, and invalid or absent repository identity.

### Complete Write Surface

- **Callers/readers:** `.github/workflows/issue-sync-reusable.yml:295-305` invokes the reconciler after separate `issue-sync-helper.sh` steps.
- **Writers/mutation paths:** `.agents/scripts/planning-publication-reconcile.sh:140-215` projects labels with `gh_issue_edit_safe`, removing `publication:pending` only after verification.
- **Tests/fixtures:** `test-issue-sync-ci-context.sh` and `test-planning-publication-reconcile.sh` cover a hosted inventory, write policy, invalid identity and exact-snapshot publication; add the missing cross-process path.
- **Schemas/config:** `issue-sync-ci-context.sh:12-62` creates a 600-permission inventory limited to `GITHUB_REPOSITORY`; non-CI callers continue using their configured local inventory.
- **Generated/deployed mirrors:** the workflow checks out framework scripts at `__aidevops/`; edit committed source, not installed user-level agent scripts, and check both script and workflow versions in CI.
- **Migrations/backfills:** N/A because `.agents/scripts/planning-publication-reconcile.sh` changes no persisted schema; held issues can be retried against an exact default-branch SHA, never cleared on an unverified snapshot.
- **Cleanup/rollback paths:** reverting the patch must leave `publication:pending` issues held, with explicit exact-SHA reconciliation through `.agents/scripts/planning-publication-reconcile.sh` available for recovery.

### Implementation Steps

1. Reproduce/verify run `36072119531` and distinguish its privacy-inventory error from an invalid task mapping or failed brief validation.
2. Initialize the existing repository-scoped CI context in the publication process or persist it safely for that workflow step, before using GitHub write wrappers. Never synthesize a broad inventory or ignore privacy-guard failures.
3. Extend an existing focused test to simulate distinct step processes without home `repos.json`, including valid and malformed `GITHUB_REPOSITORY`, unchanged non-CI behavior and the exact SHA/ref/brief guard.
4. Run both focused test scripts, `shellcheck` on changed shell files and `.agents/scripts/linters-local.sh --changed`; if editing the workflow, run its existing targeted validation too.

### Hazards and Compatibility

- **Concurrency/atomicity:** a worker may claim a correctly reconciled issue. Preserve active-status race checks instead of forcing `status:available` on claimed work.
- **Migration/rollback:** no migration; revert without clearing held issues. Keep the pending label if CI inventory, privacy or any publication validation fails.
- **Mixed-version/backward compatibility:** previous shell-step exports do not survive separate GitHub Actions `run:` steps unless written to `$GITHUB_ENV`; per-process initialization must precede write-wrapper use even when steps check out different framework versions.
- **Idempotency/retry:** a valid main snapshot can be retried safely; an invalid or stale SHA, missing `ref:GH#...`, or failed brief validation must not mutate the issue.
- **Partial failure/recovery:** keep `GITHUB_REPOSITORY` restricted to runner-owned metadata. Missing/invalid inventory fails closed with a diagnostic that excludes private data; do not mask the step's exit code.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-issue-sync-ci-context.sh
bash .agents/scripts/tests/test-planning-publication-reconcile.sh
bash .agents/scripts/tests/test-planning-publication-lifecycle.sh
shellcheck .agents/scripts/planning-publication-reconcile.sh
.agents/scripts/linters-local.sh --changed
```

The real hosted CI path should complete the publication step on a subsequent planning merge without a local `repos.json`; tests must also prove invalid context remains fenced. No production secrets or private inventory should appear in logs.

- **Surface mapping:** simulate the workflow caller and reconciler in separate processes, stub `gh` for label writes, assert only the authorized repository can be edited, and verify the final pending-label removal is still last.

### Recoverability Checkpoint

- [ ] Record a failed-step reproduction against the run ID and a passing isolated CI-context regression test.
- [ ] Leave any issue safely at `publication:pending` if the hosted fix cannot be verified.

### Scope Boundaries

Do not bypass privacy/write-policy checks, grant cross-repo permissions, change unrelated Pulse dispatch rules, or use issue text as a write-authorization source. The original security issue was reconciled separately and should not be relabelled by this task.

### Files Scope

- `.agents/scripts/planning-publication-reconcile.sh`
- `.github/workflows/issue-sync-reusable.yml`
- `.agents/scripts/tests/test-issue-sync-ci-context.sh`
- `.agents/scripts/tests/test-planning-publication-reconcile.sh`

## Acceptance Criteria

- [ ] A GitHub Actions Issue Sync planning-push run with no home `repos.json` establishes only the current repository's privacy/write inventory, then reconciles a matching open pending issue after exact-main SHA, TODO ref and brief validation.
- [ ] Invalid or absent runner-owned repository identity or a stale/mismatched TODO/brief fails closed and retains `publication:pending`; no write to another repository occurs.
- [ ] An eligible issue gains the intended `auto-dispatch`/available labels only after canonical publication, while an already claimed issue keeps its active status.
- [ ] Focused context and publication tests pass; no privacy guard, default-branch snapshot guard or existing relationship recovery step is weakened.

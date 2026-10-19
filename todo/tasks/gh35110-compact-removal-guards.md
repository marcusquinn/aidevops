# Recovery producers: validate compact receipts before native removal

Issue: #35145.
Parent: #35110. Overall objective: #35078.
Blocked by: #35144 (verified compact capture transaction; native dependency recorded).

## Execution ownership

Created from the interactive request for smaller tasks. The originating session owns implementation under the explicit manual-ownership hold in #35078/#35110. Keep `no-auto-dispatch`; do not launch a parallel worker. Only disposable fixture worktrees may be removed for verification. No installed-store cleanup, deployment or release.

## Goal and boundary

Teach the shared removal validators to consume a verified compact producer receipt while preserving legacy full-copy compatibility. Do not switch `archive_worktree_path_recoverably` to produce compact archives yet. This additive unit must leave existing production behavior and legacy suites intact.

## Implementation

Owning file: `.agents/scripts/audit-worktree-removal-helper.sh`.

- Inspect `_worktree_recovery_archive_is_valid`, `_worktree_archive_source_matches`, `_worktree_recovery_record_source_outcome`, `remove_archived_worktree_path` and `_worktree_remove_with_native_git`.
- Dispatch explicitly between a valid compact producer receipt and the existing legacy contract. A missing, malformed or changed receipt is not authority to skip verification or to reinterpret unrelated content as a valid archive.
- Require verified archive integrity, manifest/policy binding, exact source/admin identity and source-content equality. Recheck content immediately before native Git removal, after all other mutable probes.
- Preserve the existing lease/ownership, CWD, managed-lifetime, Git-lock and identity boundaries. Positive CWD activity and invalid lifetime proof must not become removable because an archive exists. Do not broaden degraded-CWD authorization.
- Keep native `git worktree remove` as the final source mutation. One force must never become two; failure leaves source and evidence intact.
- Record removal only after verifying source and Git registration absence. Keep the archive verifiable after source deletion.

## Verification

Use actual fixture Git worktrees and the engine from the prerequisite. Extend the existing audit cleanup tests with compact receipt paths, retaining existing legacy expectations at this stage.

```bash
bash .agents/scripts/tests/test-worktree-removal-audit-lib-cleanup.sh
bash .agents/scripts/tests/test-worktree-removal-audit-lib.sh
python3 .agents/scripts/tests/test-worktree-managed-lifetime.py
shellcheck .agents/scripts/audit-worktree-removal-helper.sh
git diff --check
```

## Acceptance

- [ ] A verified compact archive permits otherwise-authorized native fixture removal and survives independent verification afterward.
- [ ] Changed source content/admin identity, missing or corrupted receipt, late lock, active ownership/CWD and invalid managed proof preserve the source.
- [ ] Legacy validators and callers retain their current behavior.
- [ ] No production producer is switched in this PR.

## Scope and delivery

Tier: thinking — destructive authorization and mixed-version compatibility require careful review. Reference the existing last-content-check contract in `_worktree_remove_with_native_git`, not a new removal mechanism. The exact functions and files were found by scoped search before this brief. Keep an evidence checkpoint if a safety guard stops testing; never weaken the guard to make the test pass.

### Files Scope

- `.agents/scripts/audit-worktree-removal-helper.sh`
- `.agents/scripts/tests/test-worktree-removal-audit-lib-cleanup.sh`
- `.agents/scripts/tests/test-worktree-removal-audit-lib.sh`

PR closes only this leaf and uses `For #35110` and `For #35078` for the parents. No new runner or gate configuration.

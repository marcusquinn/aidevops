# Recovery producers: verify CLI recovery and document the cutover

Issue: #35147.
Parent: #35110. Overall objective: #35078.
Dependency: #35146 delivered by PR #35157 (`a7ec8207a`).

## Execution ownership

Created by interactive user request for smaller tasks. Keep the inherited explicit manual-ownership hold (`no-auto-dispatch`); the originating session owns verification. No deployment, release or removal of real operator worktrees/recovery buckets is authorized.

## Goal and boundary

Close the producer phase with end-to-end evidence and accurate operator documentation. This is not permission to introduce a test framework, migrate more legacy buckets, expand retention or claim that merged code is deployed.

## Work

1. Exercise the real `worktree-helper.sh remove` CLI against an isolated fixture containing staged, unstaged, untracked and ignored data. Restore the returned archive into a fresh independent target, verify exact data and Git-admin state, and verify no full recovery bucket was produced.
2. Confirm archive discoverability through supported list/inventory operations. If the engine's journal/output layout is invisible, fix the owning archive-list path without admitting scratch restores or legacy directories as compact archives. Preserve pins and default retention behavior.
3. Report measured source and archive allocated bytes separately from transaction metadata. Say explicitly whether the fixture source was retired; make no installed-store reclamation claim.
4. Review the four caller paths against the original #35110 criteria. Record checks and unresolved criteria; do not close the parent merely because one PR merged.
5. Update `.agents/scripts/worktree-archive-helper.md`, `.agents/reference/storage-lifecycle-worktree-recovery.md` and `.agents/reference/worktree-cwd-visibility.md`: new producer behavior, root precedence, receipt/restore flow, legacy compatibility and unchanged rootless/lifetime refusal rules.

## Verification

Reuse `.agents/scripts/tests/test-worktree-archive-lifecycle.py` and existing audit/lifecycle fixtures. Add only focused coverage for a material gap found in the actual CLI/list path.

```bash
python3 .agents/scripts/tests/test-worktree-archive-lifecycle.py
bash .agents/scripts/tests/test-worktree-removal-audit-lib.sh
bash .agents/scripts/tests/test-storage-inventory-helper.sh
git diff --check
```

Run the existing scoped Markdown/shell checks for changed files. Do not add or relax CI gates. Any discovered removal-safety defect is a blocker to acceptance and must be fixed and reverified, not documented as a successful rollout.

## Acceptance

- [x] Real CLI removal and independent restoration succeed for a disposable fixture, with before/after data comparison.
- [x] Produced archives are discoverable and pinned; retry does not multiply captures.
- [x] All four producers have verified coverage and no remaining production full-copy path.
- [x] Docs describe shipped behavior, not a planned or deployed state.
- [ ] #35110 is reconciled only after its full criteria are proven; #35078 remains governed by its broader criteria.

## Scope and delivery

Tier: standard — integrate observed evidence and established contracts; escalate any new destructive-policy decision instead of inventing authority. Parent reconciliation remains gated on this final child's verified merge.

### Files Scope

- `.agents/scripts/worktree-archive-helper.sh`
- `.agents/scripts/worktree-helper-cmds.sh`: print the retained archive path for the real manual CLI.
- `.agents/scripts/worktree-archive-helper.md`
- `.agents/reference/storage-lifecycle-worktree-recovery.md`
- `.agents/reference/worktree-cwd-visibility.md`
- `.agents/scripts/tests/test-worktree-archive-lifecycle.py`
- `.agents/scripts/tests/worktree_recovery_producer_cases.py`: existing producer-case mixin; no new runner or production test interface.
- `.agents/scripts/tests/test-storage-inventory-helper.sh`

PR closes this leaf and references both parents. Do not auto-close a parent before its verified close contract permits it. Record release/deployment as not requested.

## Verified acceptance evidence

The real removal CLI and archive verify/restore commands ran in an isolated Linux
user/PID namespace with native tools on PATH. This gave the unchanged process
observer a complete view of fixture processes; no host worktree or process was
hidden to permit real-data removal. The existing test reports an explicit skip,
with its source preserved, if an ordinary host cannot provide complete CWD visibility.
The acceptance run had no skips.

`test_manual_cli_removal_and_independent_restore` verifies staged/unstaged patches,
untracked and ignored data, exact HEAD/index/SQUASH_MSG bytes, source retirement,
absent Git registration, a verified removal receipt, pins, and no duplicate capture
on retry. The original repository is made unavailable before independent restore;
the restored object store has no alternates and passes Git connectivity checks.

Observed allocated bytes (`du -sk` × 1024), reproduced in both focused and full runs:

| Fixture measurement | Bytes |
| --- | ---: |
| Source working directory before removal | 45,056 |
| Compact archive | 36,864 |
| Separate transaction metadata directory | 8,192 |

The fixture source was retired. Archive plus transaction metadata equals the measured
source working-directory allocation in this small fixture; this is not a free-space
measurement or an installed-store reclamation claim. The disposable restore is
additional verification data, not included in those archive/store figures.

The existing archive lifecycle suite passed **80/80** in 96.372 seconds, including
the real CLI fixture, producer retry, list filters, malformed metadata, scratch,
legacy-layout and symlink exclusions. Removal audit passed **72/72** and storage
inventory passed. Scoped lint passed. The cleanup case module only defines tests;
run its existing `test-worktree-removal-audit-lib.sh` orchestrator for actual assertions.

### Original #35110 criteria and caller coverage

| Criterion/caller | Evidence |
| --- | --- |
| Manual `worktree-helper-cmds.sh` caller | Real CLI fixture above; audit covers native removal, late locks, source drift and cleanup leases |
| Classified `worktree-clean-lib.sh` caller | Existing audit cases exercise lock acquisition and lease loss after capture; central producer independently verifies restoration |
| `profile-readme-helper.sh` caller | #35146 boundary 28/28 and contributions 28/28; supported modes recover without fixture repair, private modes remain protected |
| Pulse `pulse-cleanup-worktree-removal-profile.sh` caller | #35146 worker-owned cleanup 40/40, including marked, intent-only and legacy profile-publication paths through the actual producer |
| Negative and regression contract | Audit 72/72, archive lifecycle 80/80; prior lifecycle 59/59, async cleanup 33/33, managed-lifetime 20 passed with one explicit native-systemd skip |
| No production full-copy use | Exact search finds `_worktree_copy_directory_once` only at its retained definition and the test-only legacy fixture caller |
| Scratch helper unchanged | Existing `recovery_path=none` sites remain; no recovery-copy path was introduced |

All four live caller sites still use `archive_worktree_path_recoverably`.
No new removal authority, retention policy, sudo use, enrollment or deployment is
introduced. Remaining delivery gate: merge this child after current-head CI/review,
then reconcile #35110 against all four delivered children. #35078 remains open for
its broader criteria; this acceptance does not retire further legacy buckets.

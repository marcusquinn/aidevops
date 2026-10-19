# Recovery producers: verify CLI recovery and document the cutover

Issue: #35147.
Parent: #35110. Overall objective: #35078.
Blocked by: #35146 (central producer cutover; native dependency recorded).

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
bash .agents/scripts/tests/test-worktree-removal-audit-lib-cleanup.sh
bash .agents/scripts/tests/test-storage-inventory-helper.sh
git diff --check
```

Run the existing scoped Markdown/shell checks for changed files. Do not add or relax CI gates. Any discovered removal-safety defect is a blocker to acceptance and must be fixed and reverified, not documented as a successful rollout.

## Acceptance

- [ ] Real CLI removal and independent restoration succeed for a disposable fixture, with before/after data comparison.
- [ ] Produced archives are discoverable and pinned; retry does not multiply captures.
- [ ] All four producers have verified coverage and no remaining production full-copy path.
- [ ] Docs describe shipped behavior, not a planned or deployed state.
- [ ] #35110 is reconciled only after its full criteria are proven; #35078 remains governed by its broader criteria.

## Scope and delivery

Tier: standard — integrate observed evidence and established contracts; escalate any new destructive-policy decision instead of inventing authority. No draft PR yet because prerequisite cutover is not shipped.

### Files Scope

- `.agents/scripts/worktree-archive-helper.sh`
- `.agents/scripts/worktree-archive-helper.md`
- `.agents/reference/storage-lifecycle-worktree-recovery.md`
- `.agents/reference/worktree-cwd-visibility.md`
- `.agents/scripts/tests/test-worktree-archive-lifecycle.py`
- `.agents/scripts/tests/test-storage-inventory-helper.sh`

PR closes this leaf and references both parents. Do not auto-close a parent before its verified close contract permits it. Record release/deployment as not requested.

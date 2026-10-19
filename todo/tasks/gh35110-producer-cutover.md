# Recovery producers: switch the central producer and all four callers

Issue: #35146.
Parent: #35110. Overall objective: #35078.
Blocked by: #35144 and #35145 (capture and native-removal guards; native dependencies recorded).

## Execution ownership

Interactive decomposition requested by the user. Preserve the explicit interactive ownership hold from #35078/#35110 with `no-auto-dispatch`; no parallel workers on these files. This issue authorizes code and disposable-fixture verification, not removal of real legacy buckets, deployment or release.

## Goal

Switch the existing central producer from full recovery directories to the already verified compact transaction. All callers must use the same result, without a parallel full copy or redundant second compact archive.

## Complete write surface

- `.agents/scripts/audit-worktree-removal-helper.sh`: replace the body of `_archive_worktree_path_recoverably_under_lock`, retaining producer serialization, privilege/store preflight, identity and pre/post Git-lock checks. Return the archive through `WORKTREE_RECOVERABLE_ARCHIVE_PATH`. No full-copy fallback on unsupported input.
- `.agents/scripts/worktree-clean-lib.sh`: `_clean_archive_worktree_recoverably` and its leased-removal caller; preserve exact lease revalidation and useful refusal diagnostics.
- `.agents/scripts/worktree-helper-cmds.sh`: manual removal must consume the same verified receipt and retain unregister/prune ordering.
- `.agents/scripts/profile-readme-helper.sh` and `.agents/scripts/pulse-cleanup-worktree-removal-profile.sh`: preserve profile provenance, ownership rechecks and failure handling while consuming compact output.
- `.agents/scripts/scratch-worktree-helper.sh`: inspection only unless exact search disproves the current no-recovery-copy path; do not create an archive needlessly.
- Legacy migration/inventory tests currently call the production producer to manufacture old-format buckets. Move only that fixture creation into a clearly test-only helper and update those call sites. Tests of the actual producer must assert compact behavior rather than switching to a legacy fixture.

## Hazards and compatibility

Use the prerequisite engine/guard APIs; do not add a new format. Unsupported state remains in place with a precise skipped reason. Retain legacy readers for historical copies. Honor documented explicit storage-root overrides. Retry must not create another capture. Retain native Git removal and all rootless/lifetime checks. An old binary must not mistake a compact artifact for a deletable legacy bucket.

## Verification

```bash
bash .agents/scripts/tests/test-worktree-removal-audit-lib-cleanup.sh
bash .agents/scripts/tests/test-worktree-removal-audit-lib.sh
bash .agents/scripts/tests/test-worktree-recovery-lifecycle-plan.sh
bash .agents/scripts/tests/test-worktree-recovery-lifecycle.sh
bash .agents/scripts/tests/test-worktree-recovery-lifecycle-apply.sh
bash .agents/scripts/tests/test-worktree-recovery-lifecycle-cache-retrofit.sh
bash .agents/scripts/tests/test-storage-inventory-helper.sh
bash .agents/scripts/tests/test-cleanup-worktrees-async.sh
python3 .agents/scripts/tests/test-worktree-archive-lifecycle.py
```

Scope the existing lint to modified files. Search exact calls to `archive_worktree_path_recoverably` and `_worktree_copy_directory_once` again before completion. Exercise all four callers through existing fixture paths; no live profile publication or Pulse dispatch.

## Acceptance

- [ ] Every producer returns verified compact evidence; no new full recovery copy is created.
- [ ] No production call to the old directory-copy helper remains for new recovery evidence.
- [ ] Failure preserves the source and does not abort cleanup of unrelated safe candidates.
- [ ] Legacy fixture migration preserves old-format regression coverage without restoring a production fallback.
- [ ] Existing removal, lifecycle and inventory tests pass.

## Scope and delivery

Tier: thinking — this switches production cleanup paths. Exact searches found four callers and legacy fixture dependencies. No open competing producer PR was found. Prerequisite APIs must be merged and re-read before implementation.

### Files Scope

- `.agents/scripts/audit-worktree-removal-helper.sh`
- `.agents/scripts/worktree-clean-lib.sh`
- `.agents/scripts/worktree-helper-cmds.sh`
- `.agents/scripts/profile-readme-helper.sh`
- `.agents/scripts/pulse-cleanup-worktree-removal-profile.sh`
- `.agents/scripts/tests/legacy-worktree-recovery-fixture.sh`
- `.agents/scripts/tests/test-worktree-removal-audit-lib-cleanup.sh`
- `.agents/scripts/tests/test-worktree-recovery-lifecycle-plan.sh`
- `.agents/scripts/tests/test-worktree-recovery-lifecycle.sh`
- `.agents/scripts/tests/test-worktree-recovery-lifecycle-apply.sh`
- `.agents/scripts/tests/test-worktree-recovery-lifecycle-cache-retrofit.sh`
- `.agents/scripts/tests/test-storage-inventory-helper.sh`
- `.agents/scripts/tests/test-worktree-archive-lifecycle.py`

The fixture helper is proposed new code; other listed paths exist. Expand scope if existing caller tests prove a missing owner; do not silently skip a failing test. PR closes only this leaf; parents remain open.

## Implementation findings and bounded scope additions

- `.agents/scripts/worktree-archive-helper.sh`: supported profile recovery exposed
  index drift during capture. A stat-only change followed by `git diff` changed
  the index hash even with `GIT_OPTIONAL_LOCKS=0`. Disable `diff.autoRefreshIndex`
  for patch capture; the existing native-removal fixture now checks exact index
  preservation after stat-only drift.
- `.agents/scripts/storage-inventory-helper.sh`: its existing HOME-unset test
  reproduced an import-time failure on unchanged main. Normalize unavailable
  HOME to an empty value within this read-only report; retain unavailable store
  classifications and zero deletion authority. Its sizing assertion now follows
  the existing separate `sizing_error` contract rather than global `error`.
- `.agents/scripts/tests/test-profile-readme-boundary.sh` and
  `.agents/scripts/tests/test-worktree-managed-lifetime.py`: exercise compact
  evidence and independent restoration instead of reading a full-copy directory.
  Profile coverage includes supported 0644 and protected 0600 inputs. The format
  still refuses unsupported permissions; production cleanup never normalizes
  user permissions or falls back to a full copy.
- `.agents/scripts/profile-readme-helper.sh`: replacing a README with a `mktemp`
  file changed ordinary 0644 content to 0600. The first draft CI run confirmed
  seven contribution-publication failures caused by that unsupported mode.
  Preserve the existing README mode during each replacement instead of changing
  permissions during cleanup. The supported recovery fixture no longer repairs
  permissions; the refusal fixture alone introduces a private operator-selected
  mode. Existing boundary and contributions fail-closed suites cover the paths.

The operator documentation and archive-list discovery work remain in #35147.

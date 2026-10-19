# Legacy Pulse compaction by dispatcher naming convention

The generator in `pulse-dispatch-worker-launch.sh` (`_dlw_precreate_worktree`)
creates `feature/auto-YYYYMMDD-HHMMSS-gh<N>`. `worktree-paths.sh`
(`aidevops_generate_worktree_path` / `aidevops_branch_slug`) makes its directory
`<repo>-feature-auto-YYYYMMDD-HHMMSS-gh<N>`. Match the whole source basename,
require a valid date/time and positive issue number, and classify it as legacy
Pulse without an operator flag or per-copy confirmation. The shared predicate
serves both reporting and compaction; a test exercises the actual generator
assignment and slug function to detect naming changes.

This is a naming policy, not cryptographic origin evidence: another tool or a
person can use the same convention. Other names stay unknown, and profile sources
are excluded regardless of name. This does not authorize raw-copy expiry.

## Ordered checks

1. Require a complete v2 recovery source, `worktree-helper.sh` /
   `recoverable-cleanup`, and recorded source removal.
2. Require its recorded UTC recovery creation time to be at least seven days old.
   Missing, invalid and future timestamps fail; filesystem mtime is not used.
3. Require the recorded common Git repository outside the bucket, including after
   symlink resolution. The exact incremental base must survive source retirement.
4. Require available registry evidence and no managed-lifetime row for the source.
   New managed generations use their existing lifecycle, not this exception.
5. Before allocating an archive, run the existing claim, owner, Git-reference and
   process guards. Readable positive CWD matches always block. Unusable observation
   always blocks. Only degraded observation can use the name/age policy, and only
   in compact-then-retire; ordinary retention cannot use this fallback.
6. Capture the incremental archive and verify integrity plus unchanged source.
   Record `legacy_pulse_compaction: true` and verification mode in the
   existing source-bound migration journal. No independent full worktree restore
   scratch is created in this mode. Normal migration retains its existing behavior.
7. Use the existing retirement plan/token, journal digest, bucket fingerprint,
   atomic claim and repeated guards. Drift or failure preserves the source or the
   claimed transaction for recovery; it never starts another unrecorded copy.

Unreadable processes are not proven absent by a name match. No sealed
lifecycle receipt is invented, no process is stopped and no global guard is disabled.
The source identity is covered by the migration digest in the retirement plan.

## Existing command sequence

For an eligible bucket, use the normal migration command without extra flags,
then the existing `retire-plan` and confirmation-bound `retire` commands through
`worktree-recovery-lifecycle-helper.sh` (not the `worktree-helper.sh recovery` router):

```text
worktree-recovery-lifecycle-helper.sh migrate --bucket <bucket> --repo <owner/repo> --base-branch <base>
worktree-recovery-lifecycle-helper.sh retire-plan --bucket <bucket>
worktree-recovery-lifecycle-helper.sh retire --bucket <bucket> --confirm <plan-token>
```

The migration
preflight avoids allocating an archive when retirement is already blocked. Finish
this sequence for one source before moving to another; do not bulk-create copies.
Do not broaden the pattern to arbitrary `auto` names or missing issue suffixes.

Final compact archives stay pinned. This policy authorizes neither their expiry
nor deleting their external Git base. Integrity checks and source hashing have
cost proportional to data; the metadata-only `legacy-report` remains separate,
bounded and fast. Its eligible count is a prefilter, not deletion authorization.

Implementation: `worktree_recovery_legacy_policy.py` (policy and guard invocation),
`worktree_recovery_migrate.py` (journal/verification), and
`worktree-recovery-retire-helper.sh` (unchanged positive-use protections).
Existing lifecycle tests cover fast migration/retirement followed by independent
restoration in the test only, staged/unstaged/ignored data, active processes,
unusable/degraded observations, profile/young sources, managed rows and base location.

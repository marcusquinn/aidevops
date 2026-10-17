# Worktree lifecycle reliability

## Objective and authority

Interactive implementation through verified PR merge. No release requested.
All execution and verification must be rootless: no sudo, system services,
privileged process inspection, or requirement to change host permissions.
User-approved ordinary worktree archive threshold: 24 hours of confirmed idle,
not creation age. Open PRs, live owners and preservation markers remain protected.
Archive expiry (30 days / 50 GiB discussed) is not enabled by this work.
Unknown legacy data must not be deleted just because its path is under /tmp.

## Independent review incorporated

- Reuse existing ownership SQLite and managed lifetime admission fences; do not
  introduce a parallel lease registry or a second supervisor.
- Inventory producers. Remove unnecessary checkouts before adding lifecycle code.
- Persist creation intent before creating real resources, then bind actual path,
  inode, administrative directory and common repository identities.
- Separate owner/admission state from resumable archive/removal operation phases.
- A dead PID, elapsed age, detached HEAD or missing registry row is not authority.
- Sealing is cooperative; it does not stop arbitrary same-user writers. Unknown
  ownership or unavailable process evidence prevents destructive transitions.
- Distinguish observed time from activity-event time; unknown activity is unknown.
- Define supported recovery contents and protect unsupported states, including
  unique ignored data, nested repositories, local LFS payloads and unfinished
  Git operations unless full preservation is explicitly proven.
- Verify archive recovery, source stability and durable receipts before removal.
  Pin/retain prerequisite Git objects; do not mistake hashes for restore evidence.
- Reconciliation must survive Pulse being stopped. Use user-level scheduling,
  bounded runs, locks, observable last-success and explicit degraded states.
- Capacity controls stop new allocations rather than overriding preservation.
- Bound attempts, not unconditional deletion: unknown/protected data may remain.

## Units, ownership, dependencies

Primary interactive session owns implementation, verification and merge.
Independent inference reviews supply advice only; no delegated implementation.

1. **W1: producer removal** — `.agents/scripts/file-size-regression-helper.sh`
   and its existing tests. Replace temporary worktree scans with Git-object reads;
   preserve exclusion, root/nested size limits and failure semantics. Verify repeated
   scans and interrupts cannot add worktree registrations or checkout directories.
2. **W2: contract consolidation** — existing `worktree-managed-lifetime.py`,
   ownership registry and creation/removal callers. Inventory exact producers,
   map persisted states and add missing rootless intent/activity evidence. Depends W1.
3. **W3: idle archival** — existing Pulse cleanup and archive helpers. Apply 24h
   only to confirmed idle ordinary trees, with PR/owner/content guards. Record
   durable archive/restore/removal evidence and idempotent recovery. Depends W2.
4. **W4: reconciliation and reporting** — reuse existing cleanup routines and
   user scheduling. Expose lifecycle, evidence source, last activity, protection,
   failure, next attempt and sizes. Verify execution without Pulse. Depends W2/W3.
5. **W5: rollout evidence** — read-only legacy inventory, then only individually
   authorized and verified migration. Never infer legacy ownership from names.
   Preserve unsupported cases, document gaps and do not claim them as cleaned.

## Acceptance matrix

- Ordinary user (nonzero uid); Linux/NixOS user systemd, Bash 3.2-compatible shell.
- Repeated successful scans: unchanged Git worktree registry and no checkout dirs.
- Errors, timeout, SIGTERM, SIGKILL at creation/archive/removal checkpoints.
- Restart and reboot invalidate stale process proofs; no guessed quiescence.
- Live descendants, late owner, PID reuse, simultaneous cleanup and changed paths.
- Binary staged/unstaged changes, merge topology, executable modes, symlinks and
  unusual filenames; unsupported Git states visibly protected.
- Archive corruption, interrupted publication, missing prerequisites, concurrent GC,
  source mutation, partial deletion and missing final receipt.
- Registry unavailable/corrupt/locked, ENOSPC and clock changes fail closed.
- Scheduler missing/stopped is observable; protected data cannot trigger forced expiry.
- Exact-head local checks, independent safety review and remote CI before merge.

## Evidence and progress

- W1 scanner defect reproduced: `scan_violations_ref` installed a RETURN worktree
  cleanup trap; nested `scan_violations_dir` replaced it. The repeated-scan test
  failed before the change and passed after switching to Git object reads.
- Checkout-free scanner committed as `ef4e14a34`. Its 10 tests pass, including
  repeated scans, root/nested limits, explicit limit override, exclusions,
  symlink exclusion and a missing ref. ShellCheck and Python compilation pass.
- Observed existing temporary detached worktrees and stale prunable registrations.
  Neither observation is deletion authorization.
- Independent architecture review completed; destructive rollout requires the
  safety/coverage refinements above, not a promise of universally perfect cleanup.
- Implementation environment reports uid 1000. Rootless remains an acceptance gate.

### W2 foundation implemented, not connected to automatic removal

- `worktree_lifetime_idle.py` stores a versioned idle observation inside the
  existing managed-lifetime record, using boot ID, generation, ownership epoch,
  wall time and monotonic time. Both elapsed clocks must reach 24 hours.
- `observe-idle` confirms managed descendant quiescence without sealing; failed
  observations durably invalidate previous evidence. `idle-ready` is advisory.
  `seal-idle` rechecks ownership, interval and quiescence in a writer transaction.
- Ownership insert/update/delete triggers reset idle even for sealed records.
  Reservation and binding also invalidate idle. Pending admission, live or
  inaccessible owners, corrupt timestamps and stale boot evidence fail closed.
- Independent safety review found rollback preserving old idle, sealed-owner
  mutation exemptions and missing readiness ownership checks. All three were
  fixed and covered by focused regression tests.
- `AIDEVOPS_TEST_SYSTEMD=1 python3 .agents/scripts/tests/test-worktree-managed-lifetime.py`
  passed 20 tests without skips at UID 1000, including real user-systemd child
  lifetime, guard, archive/native removal and rejection of premature idle expiry.
  This exercises the existing full-copy recovery path, NOT a new compact archive
  restore verifier or the still-unimplemented idle cleanup integration.

### Initial producer inventory and next safe action

Literal production call-site search (`git grep 'worktree[[:space:]]+add'`)
identified remaining checkout producers. This is not a complete dynamic-call audit:

- Temporary analysis: `complexity-regression-helper.sh`,
  `markdownlint-diff-helper.sh` and review bootstrap paths.
- Publication/maintenance: release aggregate/reconcile helpers, profile README,
  shared TODO commits, workflow sync, skill update and branch cleanup helpers.
- Worker/interactive creation: `worktree-helper-add.sh`, dirty-PR sweep,
  quality-debt, repository initialization and WordPress plugin creation.
- Recovery: `worktree-archive-helper.sh restore` creates a real linked worktree.

Continue by tracing creation intent and cleanup ownership for these producers,
then integrate idle eligibility into ordinary cleanup without age-based fallback.
Do not connect deletion until archive restore verification, source revalidation
and generation-bound cleanup authorization are implemented. Cleanup ownership
itself invalidates idle, so a separate durable operation receipt is necessary;
generic `proof` or an old `seal` is not 24-hour idle authorization. W3–W5,
independent final review, remote CI and merge remain outstanding. No archive
expiry, legacy deletion or deployment has been enabled by these changes.

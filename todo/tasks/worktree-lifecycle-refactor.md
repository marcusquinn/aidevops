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

- Confirmed producer defect by source inspection: `scan_violations_ref` installs
  a RETURN worktree cleanup trap; nested `scan_violations_dir` replaces that trap.
  Runtime reproduction still required; no source implementation edits yet.
- Observed existing temporary detached worktrees and stale prunable registrations.
  Neither observation is deletion authorization.
- Independent architecture review completed; destructive rollout requires the
  safety/coverage refinements above, not a promise of universally perfect cleanup.
- Implementation environment reports uid 1000. Rootless remains an acceptance gate.

# t18849: stop .archive-verify-* scratch leaks from killed archive verification and unbounded prune

Ref: GH#36468

## What

Stop `.archive-verify-*` scratch directories from accumulating beside recovery archives, and reclaim the ones already orphaned.

## Why

Observed on one host: 160+ orphaned `.archive-verify-*` directories under `~/.aidevops/recovery/archives/<repo>/<task>/`, each 50-220 MB (partial bare repos holding an imported base graph). Several archives carry 5-15 of them.

Root cause (verified):

- `verify_in_scratch` (`.agents/scripts/worktree_archive_objects.py:119`) creates scratch and removes it only after success. Earlier code used `tempfile.TemporaryDirectory`, which also cleans up only when Python is allowed to unwind.
- Callers bound the helper with `subprocess.run(timeout=...)`, which sends **SIGKILL**, so no `finally`/`rmtree` runs:
  - `.agents/worker-lifecycle/worker_lifecycle/preservation.py:50` → 120 s
  - `.agents/scripts/worktree_archive_prune.py:33` → 60 s
- The inner work is budgeted much higher: `base_import_timeout()` defaults to 300 s (`worktree_archive_git.py:126`), plus `fsck --full`.
- Measured: `worktree-archive-helper.sh verify` on a 16 KB delta archive took **57 s** on an idle host (base import dominates). Under load it overruns 60/120 s, the child is SIGKILLed, and scratch leaks on every retry.
- Main producer: compact retention (`cleanup-worktrees-async-helper.sh:253`, `timeout_sec 120 ... prune`). `prune` runs a full `verify` on **every** archive before selecting anything (`worktree_archive_prune.py:57`, inside `inspect`), even in dry-run. With ~60 s per archive, the pass can never complete. The log shows `rc=124` on every run, and each new scratch directory appears 1-12 s before the kill. About 300 MB leaks per pass (10-15 GB/day observed, quota rising ~6 GB in one morning), and retention has never completed once, so it cannot be enabled.
- Since ce8e2732a (GH#36281) the scratch name is a deterministic per-archive hash used as a retry fence. One kill now makes that archive permanently unverifiable (`archive-verify:retained-scratch; review required`), so prune keeps it forever and recovery/compaction stops.

## How

1. **Cooperative cancellation.** Callers stop the helper with SIGTERM, wait a grace period, and only then SIGKILL. Run it in its own process group so Git children receive the signal too. The verifier converts SIGTERM into an exception so cleanup runs.
2. **Liveness-based fencing instead of an evidence fence.** The verifier holds an exclusive `flock` on the per-archive scratch for its lifetime:
   - Another verifier holds the lock: fail fast with a "busy" result. This keeps the concurrency fence.
   - No holder (owner died, including by SIGKILL or power loss): the scratch is stale. Remove it with symlink-safe `rmtree` and proceed.
   - Scratch content is a reproducible derived copy, not evidence; the diagnostic is the classified stderr.
3. **Prune selects before it verifies.** Select candidates from cheap metadata (`created_at`, size). Verify only the archives actually being removed (`remove_verified` already re-verifies after claiming), with a self-imposed deadline so the pass ends cleanly and defers the rest instead of being killed.
4. **Consistent budgets.** Caller timeouts must exceed the inner base-import budget plus the grace period.
5. **Sweep legacy orphans.** Existing randomly-named `.archive-verify-<mkdtemp>` directories are reclaimed by the archive maintenance path (`cleanup-worktrees-async-helper.sh`). The sweep removes only real directories (no symlinks), directly under an archive task directory, with no live lock holder, older than a safety window, using no-follow descriptors. It is independent of the archive retention mode: the directories hold no unique data.

### Files to Modify

- EDIT: `.agents/scripts/worktree_archive_objects.py` — lock/stale-recovery in `verify_in_scratch`; SIGTERM handling
- EDIT: `.agents/scripts/worktree_archive_git.py` — retire the `retained-scratch` permanent refusal message (busy diagnostic instead)
- EDIT: `.agents/worker-lifecycle/worker_lifecycle/preservation.py` — graceful termination and budget
- EDIT: `.agents/scripts/worktree_archive_prune.py` — graceful termination and budget for `verify`
- EDIT: `.agents/scripts/worktree-archive-helper.sh` + `.agents/scripts/cleanup-worktrees-async-helper.sh` — scratch sweep
- EDIT: `.agents/scripts/tests/worktree_recovery_producer_cases.py` — update the retained-scratch expectations

### Files Scope

- .agents/scripts/worktree_archive_objects.py
- .agents/scripts/worktree_archive_git.py
- .agents/scripts/worktree_archive_scratch.py
- .agents/scripts/worktree_archive_prune.py
- .agents/scripts/cleanup-worktrees-async-helper.sh
- .agents/worker-lifecycle/worker_lifecycle/preservation.py
- .agents/scripts/tests/worktree_recovery_producer_cases.py

## Acceptance Criteria

- [ ] Killing a running `verify` (SIGTERM, or SIGKILL via timeout) followed by a retry verifies successfully, and no `.archive-verify-*` remains afterwards.
- [ ] Two concurrent verifications of the same archive never share or delete each other's scratch.
- [ ] The maintenance sweep removes the legacy orphans on the reporting host; archives and their `manifest.json` are untouched.
- [ ] Existing producer/prune tests pass; ShellCheck is clean.

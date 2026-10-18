<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worktree lifecycle: rootless, recoverable, guarded (GH#34943)

Supersedes the plan cited by GH#34905, which never landed on any branch. This
file records the lifecycle contract, proof requirements, producer inventory,
recovery checks and verification evidence. Line references are navigation
anchors; recheck them before editing.

## Contract

One lifecycle, reusing existing components. No parallel supervisor.

| Concern | Owner |
|---|---|
| Ownership/leases | `shared-worktree-registry.sh` / `.py` (`worktree_owners`) |
| Managed descendant lifetime | `worktree-managed-lifetime.py` (enroll → reserve → bind → seal → proof), same SQLite DB |
| Idle classification | `pulse-cleanup-worktree-state.sh` `_worktree_idle_since_epoch` |
| Candidacy and policy windows | `pulse-cleanup-worktree-removal.sh` (`_pc_*_archive_secs`, `_cleanup_single_worktree`) |
| Recovery archive | `worktree-archive-helper.sh` (`archive`, `verify`, `source-matches`, `restore`) |
| Final removal fence | `audit-worktree-removal-helper.sh` (`worktree_removal_guard`, `worktree_managed_require_removal_proof`, `_worktree_remove_with_native_git`) |
| Temp fixture sweep | `pulse-temp-worktree-cleanup.sh` (detached `tmp.*` paths only) |

## States and proof requirements

| State | Entered when | Leaves only with |
|---|---|---|
| created | `git worktree add` succeeds | registration (helper paths) or Git metadata only (see inventory) |
| owned | live registry lease or live owner PID | lease release/expiry evidence |
| idle-confirmed | `.git`, admin `HEAD` and HEAD reflog all older than window; every signal mandatory | any newer signal returns to active |
| candidate | idle-confirmed AND no active owner AND no open head PR AND no preservation marker AND not locked | — |
| archived | compact archive written and `verify` passes; source fingerprint unchanged across capture | `source-matches` re-check immediately before removal |
| removed | guard + managed-lifetime fence + native `git worktree remove` (never raw `rm` on a registered path) | — |
| preserved | any unknown/unavailable evidence at any step | re-evaluation next cycle |

Invariants:

- Unknown ownership, process, idle, PR or registry evidence preserves (fail closed).
- The managed-lifetime fence fails closed without a registry; enrolled worktrees
  need a sealed generation with drained descendants.
- Late locks or writes after the guard abort native removal (Git double-force rule;
  `source-matches` fingerprint).
- Compact-archive expiry stays `dry-run` by default
  (`storage.worktree_archive_retention_mode`); irreversible expiry is not activated.
- Process guards are not weakened.

## Timing policy (unresolved; maintainer decision required)

Requested target: archive candidacy after 24 hours of confirmed idle for
ordinary worktrees. Current enforced defaults, now user-configurable in
`.agents/configs/aidevops.defaults.jsonc` `storage` (minimum 24 h; smaller or
malformed values fall back to the default):

| Class | Key | Default |
|---|---|---|
| Local commits | `worktree_local_commit_archive_hours` | 168 (7 d) |
| Dirty generated auto/review | `worktree_generated_dirty_archive_hours` | 168 (7 d) |
| Unattributed, no open head PR | `worktree_unattributed_archive_hours` | 336 (14 d) |

Configurability does not resolve the policy. Shipped defaults stay unchanged
until the maintainer records a decision here.

Decision: _pending_.

## Producer inventory

Production `git worktree add` sites (excluding `tests/`). P = Pulse age pass
(`pulse-cleanup-worktree-removal.sh:2076-2108`), which enumerates every
Git-listed worktree, detached included, for non-`local_only` repos in
`repos.json`; it still applies every guard. EXIT = EXIT trap only, so signal
cleanup is not guaranteed and SIGKILL is never covered.

| Site | Kind | Registry | Cleanup | Signal | Sweep |
|---|---|---|---|---|---|
| `worktree-helper-add.sh:1170` | detached fetch bootstrap | none | end-of-function raw remove | no | P |
| `worktree-helper-add.sh:1273,1288,1301` | named | register + conditional enroll + claim | persistent; `worktree-helper.sh remove` (audited archive-first) | n/a | P |
| `pr-review-thread-response-scanner.sh:1974` | detached fetch bootstrap | none | end-of-function raw remove | no | P |
| `profile-readme-helper.sh:2068` | detached | registered | end + EXIT; audited archive fallback | EXIT | P |
| `wp-plugin-new-helper.sh:441` | named | none | persistent PR worktree | n/a | P if managed |
| `aidevops-cli/aidevops-repos-lib.sh:1045` | named fallback | none | handed to user | n/a | P if managed |
| `full-loop-release-reconcile.sh:1269` | detached | none | EXIT raw remove | EXIT | P |
| `shared-todo-commit.sh:524` | detached | none | finalizer raw remove | no | P |
| `pulse-quality-debt.sh:66` | named canonical sibling | none | worker/PR lifecycle | n/a | P, orphan-sibling relocation |
| `remote-branch-cleanup-helper.sh:241` | detached transport | none | EXIT raw remove | EXIT | P |
| `local-branch-cleanup-helper.sh:247` | detached no-checkout | none | EXIT raw remove | EXIT | P (eligibility unverified) |
| `full-loop-release-aggregate-recovery.sh:708,733` | detached | none | EXIT raw remove | EXIT | P |
| `full-loop-release-aggregate-recovery.sh:780` | detached reconstruction | none | retained as evidence | no | P |
| `full-loop-release-helper.sh:99,459` | detached | none | EXIT raw remove; failed prep retained | EXIT | P |
| `worktree-archive-helper.sh` `restore` | named restore | none | intentionally retained | n/a | P if managed |
| `sync-workflows-helper.sh:293` | detached fetch bootstrap | none | end-of-function raw remove | no | P |
| `sync-workflows-helper.sh:357` | named | best-effort register | persistent | n/a | P |
| `skill-update-pr-lib.sh:432,437` | named sibling | registered | audited permanent removal on failure | no | P |
| `pulse-dirty-pr-sweep.sh:874` | named ephemeral | none | EXIT/INT/TERM/HUP trap (this branch) | yes | P |
| `install-hooks-helper.sh:1766`, `install-hooks.sh:201` | named self-test under `mktemp` | none | end raw remove + `rm -rf` | no | none |
| `frontier_harness_agent.py:116` | container-only | none | container teardown | n/a | none (not host-owned) |

Read-only scanners (file-size, complexity, markdownlint/biome baseline) create no
worktrees: they use unregistered `git-ref-snapshot-lib.sh` snapshots (#34926, #34935).

### Gaps (follow-up candidates; not changed here)

1. Fetch bootstraps (`worktree-helper-add.sh:1170`, scanner `:1974`,
   `sync-workflows-helper.sh:293`) lack signal cleanup and audited removal; a
   shared owned scratch-worktree helper would cover all three.
2. Release helpers use raw `git worktree remove` in EXIT traps and their own
   stale reaper, bypassing the audit fence.
3. Hook self-test fixtures are named branches under `mktemp`, outside every sweep
   (temp sweep requires detached).
4. Unregistered named producers (`pulse-quality-debt.sh`, `wp-plugin-new-helper.sh`,
   repos fallback) rely only on Git metadata for ownership evidence.
5. `restore` accepts an arbitrary target; local-only repos are outside P.

## Scanner edge cases (item 4)

Delivered on this branch: NUL-delimited filename discovery; filter/attribute/
symlink behaviour verified for parity rather than assumed. Evidence is in the
commit history (`f6289a3f98`) and the Linux run below.

## Verification evidence

Linux: Ubuntu 24.04.5, aarch64, unprivileged uid 1001, Bash 5.2.21, Git 2.43.0,
Python 3.12.3. "base" is unchanged `origin/main` run in the same container.

| Check | macOS (Bash 5) | Linux new | Linux base |
|---|---|---|---|
| `test-file-size-regression-helper.sh` | pass | pass | pass |
| `test-complexity-regression-helper.sh` | pass | pass | pass |
| `test-markdownlint-diff-gate.sh` | pass | pass | pass |
| `test-worktree-managed-lifetime.py` | pass | 10 OK (1 skip) | same |
| `test-worktree-archive-helper.sh` | pass | pass | pass |
| `test-worktree-archive-lifecycle.py` | pass | 11 OK | 11 OK |
| `test-worktree-recovery-lifecycle.sh` | 59/59 | 59/59 | 21 fail (fixture) |
| `test-pulse-cleanup-worker-owned-no-pr.sh` | 40/40 | 40/40 | 24/39 |
| `test-worktree-removal-audit.sh` (lib) | 62/62 | 62/62 | 53/62 |
| `test-pulse-cleanup-preserves-dirty.sh` | 4/5 | 4/5 | 4/5 (same test) |
| `test-pulse-cleanup-unregister.sh` | 1 fail | 1 fail | same fail |
| `test-pulse-temp-worktree-cleanup.sh` | — | 12/14 | 12/14 (same tests) |
| `test-dirty-pr-sweep.sh` | pass | 23/0 | 23/0 |
| dirty-PR SIGTERM, group + parent kill | — | 0 leaked registrations/branches | 1 leaked registration + 1 branch per run |

Bash 3.2 (macOS `/bin/bash` 3.2.57 runs each suite's top-level shell; nested
`bash` children still resolve to PATH Bash 5): file-size 9/9, complexity 17/17,
markdownlint gate, archive helper, recovery lifecycle 59/0, worker-owned 40/40
and dirty-PR sweep 23/0 all pass. The same three pre-existing failures appear as
under Bash 5. The audit suite exposed one test-only 3.2 defect: an EXIT trap
deferred-expanded a function local after it was unset under `set -u`. It is
fixed by expanding at trap definition. `test-pulse-temp-worktree-cleanup.sh`
"TODO-sync … hidden identity" passes on macOS and fails on Linux new and base
alike (Linux process-identity evidence; pre-existing).

### Fault matrix → existing coverage (all passed on macOS and Linux new)

| Scenario | Evidence |
|---|---|
| Repeated scans, SIGTERM/SIGKILL | #34926/#34935 scratch-clone runs; dirty-PR SIGTERM row above |
| Timeout | recovery `cache_retrofit_honors_shared_deadline_before_mutation` |
| Interrupted removal | recovery `apply_resumes_move_and_delete_crash_windows`, `apply_resumes_transaction_initialization_crashes`, `cache_retrofit_resumes_interrupted_{move,delete}`, `automatic_maintenance_resumes_interrupted_apply` |
| Interrupted creation | managed `never_admitted_creation_can_be_closed`; **gap**: `worktree-helper-add.sh` create→register window has no test |
| Live descendants | managed `live_descendants_and_reused_invocation_refuse`, `kernel_populated_veto`, `native_child_lifetime_and_guard` |
| Concurrent cleaners | recovery `shared_producer_lock_fails_closed_and_reclaims_stale`, `receipt_reservation_blocks_conflicting_plan`; audit `recoverable_archive_honours_shared_producer_lock`; managed `trigger_fences_claims_but_allows_cleanup_retry` |
| Late owners / locks | audit `recoverable_cleanup_preserves_lease_loss_after_archive`, `manual_degraded_recheck_requires_live_exact_lease`, `permanent_helper_preserves_lock_acquired_after_guard`, `recoverable_archive_preserves_late_lock`; lifecycle `pin_added_during_verification_preserves_claimed_archive` |
| Reboot / unknown evidence | managed `absence_is_distinct_from_invalid_evidence`; audit `unreadable_process_listing_matches_degraded_visibility`; recovery `plan_records_malformed_bucket_unknown`; boot-ID check in `drain()` is code-enforced, **no dedicated test** |
| Source mutation | archive `source_matches_detects_late_writes`; worker-owned `late_write_after_compact_archive_preserves_worktree`; audit `recoverable_archive_refuses_late_unarchived_write_without_force` |
| Corrupt archives | lifecycle `corrupt_and_unknown_archives_are_preserved` |
| Missing Git prerequisites | audit `permanent_helper_fails_closed_on_{unreadable,ambiguous}_git_metadata`; missing git binary: **unknown** |
| Unsupported recovery states | recovery `automatic_maintenance_reports_unsupported_process_visibility`; audit `recovery_inventory_reports_legacy_buckets_fail_closed` |
| Capacity exhaustion | recovery `automatic_maintenance_checks_capacity_before_aggregate_size`; lifecycle `size_pressure_evicts_oldest_unpinned`; audit `recovery_store_permission_preflight` |
| Recovered contents/state | audit `recovery_archive_preserves_index_and_dirty_files`, `recovery_archive_preserves_detached_head_identity`; lifecycle `roundtrip_many_commits_merge_and_dirty_state_from_base_only` |

Base-only failures come from non-hermetic fixtures (host registry, `/var` vs
`/private/var`, host git shim), not product behaviour. Identical failures on new
and base are pre-existing (see below).

Scanner edge cases (fixture: 11 changed files, including names with space, tab,
quote, backslash, colon, non-ASCII, leading dash and newline):

- Zero temporary worktree registrations after all scans; the only listed
  worktree is the fixture's main checkout.
- Complexity: base scanned 6 applicable files and reported 1 new violation; new
  scans 10 and reports 2. Base `git diff --name-only` quoting dropped
  `docs/sp<TAB>ace.sh`; NUL-delimited discovery fixes it. This is an intended
  correctness change, not a parity break.
- Newline-containing paths are skipped with an explicit
  `[git-ref-snapshot] WARN` rather than scanned (documented limitation).
- Markdownlint parity is unverified in the container: both report 0 violations,
  consistent with no markdownlint binary present.
- File-size filter/symlink parity fixture: base 2 / head 2 / new 0, no regression.
- Retention config: CLI-set 24 h resolves to 86400 s; validation ran without a
  JSON Schema validator (none installed).

Test-fixture hermeticity fixes (`40235f3ffe`, `1b8c7bc323`): canonical fixture
roots, fixture-owned ownership registries (never the host registry), and a
shim-free PATH for removal race tests. A deployed aidevops git shim correctly
rejects non-native `AIDEVOPS_REAL_GIT_BIN` wrappers.

Pre-existing on unchanged `main`: `test-pulse-cleanup-unregister.sh`
"eligible orphan worktree was not removed". The test expects permanent removal
of an issue-less branch with no repo slug. Since `df97f104c59`, unattributed
worktrees require PR-state evidence and compact archival, so the expectation is
stale. Not repaired here.

Also pre-existing on unchanged `main` (identical on Linux new and base):

- `test-pulse-cleanup-preserves-dirty.sh` "dirty worktree past 6h refused by
  defence-in-depth": the worktree is retained as `unattributed-retention`
  (14-day window), which is safe, but the test asserts a 6-hour dirty rule
  audit reason.
- `test-pulse-temp-worktree-cleanup.sh`: "TODO-sync cleanup fails closed for a
  live PID with hidden identity" and "orphan cleanup compares against
  origin/main when local main is stale".

## Independent safety review

A static review over staged branch files returned BLOCK with four findings.
All four were confirmed in the code and fixed:

1. Dirty-PR ephemeral cleanup ignored a refused `worktree remove` and then ran
   `rm -rf` and an unconditional `branch -D`. Now native removal is the only
   remover: a refusal (lock, unregistered path) preserves the directory and
   branch. Removal also needs invocation-owned evidence: a random owner token
   written into the worktree's admin directory at creation, and a branch tip
   this run produced (the creation tip, or its rebase result taken from the
   branch's own `rebase (finish)` reflog entry so a later commit is never
   adopted). Anything else preserves both the worktree and the branch,
   including an unresolvable branch tip while the checkout still exists. The branch is then deleted with
   `update-ref -d <ref> <that-tip>` (compare-and-swap), and only when it is not
   checked out elsewhere. Pre-add failure paths use `rmdir`.
2. `source-matches` ran before native removal's lock, common-dir and
   managed-lifetime probes. It now runs inside `_worktree_remove_with_native_git`
   (new 6th argument) after every probe, immediately before `remove --force`.
   The pre-existing third-party removal path, which used only a porcelain
   snapshot, gets the same check. The late-write test now injects the write at
   the managed-lifetime probe. The residual race is the native removal call itself.
3. The fingerprint now fails closed on skip-worktree or assume-unchanged index
   entries. It also covers every ignored file's lstat stamp (mode, inode, size,
   mtime_ns, ctime_ns), the same stat check Git uses for its own index. A late
   write anywhere in ignored content therefore blocks removal. More than
   `AIDEVOPS_WORKTREE_FINGERPRINT_MAX_IGNORED` (default 200000) ignored files,
   or any unreadable entry, fails closed.
4. A failed checkout filter in `scan-ref` was counted as zero lines. It now warns
   with the path and counts the unfiltered blob.

Also, as non-blocking: markdownlint arguments that contain glob metacharacters
now use the `:` literal form. `test-pulse-cleanup-centralize-worktrees.sh`
failed 3/6 on unchanged `main` because it had no fixture registry; it now has a
fixture-owned registry and passes 6/6.

An ad-hoc probe passed 14/14 on Bash 5.3 and 3.2. It covered: locked
ephemeral, mismatched or empty owner token, a foreign commit before cleanup, an
unresolvable branch tip with a live checkout, a branch advanced during cleanup,
owned removal, skip-worktree, assume-unchanged, a new ignored file, a same-size
overwrite deep in an ignored directory, the ignored-file cap, and a failing
smudge filter. An end-to-end probe of `_dps_rebase_in_ephemeral` against a
local bare origin also passed under Bash 5: success with push, conflict, and
TERM mid-rebase each left zero worktrees and zero `dirty-pr-sweep/*` branches.
The `/bin/bash` invocation re-execs into modern Bash, so it is not 3.2 evidence.

Review rounds: the first re-review closed findings 2 and 4. The second closed
finding 3 for ordinary writes. It is metadata comparison, not content
verification: a writer that preserves mode, inode, size, mtime and ctime would
evade it, which ordinary tools cannot do for ctime. The second re-review
also found finding 1 failing open on an unresolvable branch tip; that is
now fixed. The third re-review returned APPROVE-WITH-NOTES with finding 1
closed. Its notes: a reflog subject names an operation type, not an
invocation, so a concurrent foreign rebase or a forged subject is not
excluded; and the final check-to-removal race remains.

Found while probing, and outside this scope (identical on `main`): `rebase -X
union` does not resolve TODO.md conflicts. `union` is a merge driver, not a
strategy option, and no `merge=union` attribute applies, so the TODO-only
auto-rebase never succeeds. Filed as GH#34947 (t18713).

Outstanding: NixOS execution, concurrent cleaners and late owners,
interrupted creation/removal, the timing decision, and exact-head CI.

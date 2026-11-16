<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Archive-fixture timeouts and retention backlog (GH#38659, child of #35359)

Measured 2026-11-16 on one Linux host (16 cores, load average 12.8 at start, 4.5 GB free disk),
Python 3.13, unmodified `origin/main` a32db23d2 unless noted.

## Verdict

Both causes are present; they are separable:

1. **Product code does repeated process-spawning work (primary).** One `retire-plan` on a
   one-file fixture executes about 1,850 processes (strace `execve`, non-ENOENT): ~680 `git`,
   ~320 `dirname`, ~290 `readlink`, ~165 `python3`, ~150 `bash`, ~50-100 `jq`. Wall time per
   lifecycle subcommand is 6-10 s on that tiny fixture. Test-side Python is ~0.1 s of a 27.7 s case
   (cProfile): the time is subprocess fan-out, not fixture size or data copying.
2. **Host load multiplies it (secondary).** At load 12.8/16 each fork+exec costs several ms, so
   the fan-out above becomes the 60 s per-call budget (`run_command`, `timeout=60`) on a busier
   canary. Startup of one helper is cheap (`worktree-archive-helper.sh --help` 0.05 s), so this is
   not interpreter or import cost.
3. **Host free space, not time, caused 19 of 183 failures here.** `worktree-helper-add.sh` refuses
   `restore --target` below `AIDEVOPS_MIN_WORKTREE_FREE_KB` (default 5 GiB); this host had 4.5 GB.
   Fixture worktrees are a few KB, so the guard is irrelevant to what the tests assert.

## Timings (before)

| Case | Result |
|------|--------|
| Full `test-worktree-archive-lifecycle.py` (183 tests) | 1401 s (avg 7.7 s/test); exceeds any 300 s bound |
| Slowest cases | `auto_merge_verified_legacy_retirement` 35.3 s; `producer_transaction_round_trip_and_retry` 27.5 s; `git_only_migration_ignores_abandoned_history` 25.4 s; `legacy_managed_archive_does_not_authorize_removal` 25.0 s; 20 more cases at 16-24 s |
| `test-worktree-archive-helper.sh` | 106 s, 4 of 12 failed (capacity guard only) |
| `auto_merge_verified_legacy_retirement`, per call | `migrate` 5.9 s, `retire-plan` 8.2 s, `retire` 8.7 s, `restore` 2.5 s, 23 subprocess calls |

Removing `~/.aidevops/bin` (the git safety wrapper) from `PATH` did not change these numbers
(28.8 s vs 26.0 s), so the git guard wrapper is not the hot path.

## Retention backlog classification

No live retention data was read or deleted on any host (constraint). From the code and the
reference doc, hard-link/special-permission and process-unavailable reasons are fail-closed
retention guards, and `classification-deadline-exhausted` is the deadline path. Both are expected
retention while the classification pass cannot finish inside its budget. They stop being merely
expected when the fan-out above makes the pass exceed its deadline: then `source_bytes_retired`
stays 0 because of cost, not because of a safety finding. That link is inferred from the timings
above; it needs one measurement on a canary with the real backlog to confirm.

## Change made

- Fixtures in `test-worktree-archive-lifecycle-cases.py` and `test-worktree-archive-helper.sh` set
  `AIDEVOPS_MIN_WORKTREE_FREE_KB=0` and `AIDEVOPS_MIN_WORKTREE_FREE_PERCENT=0`, so host free
  space no longer decides results. Retention guards and product code are unchanged. No timeout
  was raised.

`test_tracked_patch_capacity` in the shell suite unsets both overrides for its archive call: with
them set to 0 it failed on this host (2 of 2 runs) and with them unset it passed; the reason was
not root-caused (the archive helper does not read them directly).

## Results (after, same host)

- `test-worktree-archive-helper.sh`: 12 tests, 0 failures (was 4 failures), 146 s.
- The 5 lifecycle cases that failed on the capacity guard, plus 3 more spot-checked, pass.
  The full 183-test suite was not re-run after the change (about 23 min on this host); the 19
  capacity failures all came from the same `restore --target` guard.
- Per-case slowness is unchanged: the fan-out is not fixed here, so the full suite still takes
  roughly 23 min at this load and does not meet the 300 s bound.

## Remaining blocker (tracked in #38675, not resolved)

Reduce subprocess fan-out in the lifecycle path. Starting points from the strace profile:
`rev-parse --absolute-git-dir` / `--git-common-dir` and `config` repeated per path,
`worktree list --porcelain` repeated about 6 times, `remote get-url origin` and
`branch-has-active-claim` re-run per candidate, and shell helpers re-resolving their own
directory through `dirname`/`readlink`. Target files are unknown until a per-phase profile
(`AIDEVOPS_RECOVERY_TIMING_LOG`) isolates the loops in `worktree_recovery_migrate.py`,
`worktree_lifetime_archive.py` and `worktree-recovery-lifecycle-helper.sh`. Verification: the
three slowest fixtures under 10 s each and the full suite under 300 s on the same machine.

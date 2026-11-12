<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GH#37893: circuit-breaker trip #37892 investigation

## Trip

- Notification: #37892 (2026-11-12T13:51:32Z), 3/3 consecutive failures, task `disk-pressure`.
- Reason: `interactive: worktree lifecycle never authorizes retirement; disk fell 76G to 53G in 50min while reclaiming; pausing dispatch during fix`.
- Classification: an interactive session recorded the failures on purpose to pause dispatch. No worker failed, and canary, credential or CLI-drift hypotheses do not apply. The breaker was still OPEN at investigation time (`aidevops circuit-breaker status`), and the 1800 s auto-reset was pending.

## Evidence (tripping runner, `~/.aidevops/logs/cleanup_worktrees.log`)

| Signal | Observation |
|--------|-------------|
| Pressure-mode runs | `reason=capacity-pressure` occurs 0 times in the log; 44 passes ran on 2026-11-12, all on the routine budget |
| Lifecycle retirement per pass | Last 24 `Lifecycle cleanup:` lines: `retired=1..5`, `failed=0..4`, `held` up to 21 |
| Legacy pass per run | `removed=3..8 archived=3..8` |
| Held/retained reasons | `too-recent` (up to 56), `nonempty-worktree-state` (up to 15), `managed-admission-not-closed`, `preservation-name`, `head-not-on-remote`, `proc-observation-unavailable` with `cause=inspection-not-enabled` (opt-in protected inspection, `protected_proc.py:70`) |
| Failures | `CalledProcessError returncode=1` on subprocess retirement steps; one `worktree-archive-helper.sh verify-local` failure with `quarantine_failures=10` |
| Lifecycle reconcile | Every run: `examined=5 truncated=true attempted=0` |
| Inventory | ~82 linked worktree directories, 52 created that day; one managed repo with 80 registered worktrees |
| Disk | Reported 76 G to 53 G free in 50 min; 69 G free on a 590 G volume (88 % used) at investigation time, after interactive reclaim |
| Not the consumer | Recovery archive root 2.8 G, sandbox temp 1.5 G, trash 27 M |

## Root cause

`_worktree_pressure_present` (`.agents/scripts/cleanup-worktrees-async-helper.sh:442`) signals pressure in only two cases:

1. `aidevops_worktree_capacity_check` fails (`.agents/scripts/disk-capacity-lib.sh:54`). That check is the hard worktree-creation floor of 5 GiB or 5 % free (~29.5 G here).
2. A repo reaches the count threshold of 150 (the cap was raised to 1000 in GH#37498).

At 53 G (9 %) free and 80 worktrees, neither fires. Cleanup therefore stays on the routine budget and cadence, and retires a few trees per pass. Meanwhile workers add worktrees and consume ~23 G per 50 min. Disk is the binding resource. `disk-capacity-lib.sh:77-80` already names disk as the primary guard, but cleanup only escalates once creation is already refused. Retirement refusals (too-recent, non-empty state, opt-in process inspection, subprocess failures) further cut the per-pass yield. That is the "never authorizes retirement" half of the trip, which the interactive session is fixing.

## Outcome

- Fix task filed: #37895 (`Ref #37892`). It adds a soft disk-headroom pressure trigger above the creation floor and changes only budget and cadence, not eligibility.
- Retirement-authorization fix: owned by the live interactive session on branch `fix/worktree-retirement-authorization`. #37895 carries a coordination note.
- Not transient: the trigger gap is structural and will recur whenever worker disk use outpaces routine cleanup. Do not close #37892 as transient.

## Verification of the fix (from #37895)

- `shellcheck` on the two helpers, plus `bash .agents/scripts/tests/test-cleanup-worktrees-async.sh`.
- Runtime: with the soft threshold set above current free space, `cleanup_worktrees.log` shows `reason=disk-headroom`, and the pass ignores cadence.

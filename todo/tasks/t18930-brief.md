## What

When an interactive session finishes a full loop (`full-loop-helper.sh complete`, the `CLEANUP_DEFERRED` handoff), let it release both locks it holds on that worktree. Then the guarded Pulse cleanup can retire the tree while the OpenCode app keeps running. Today the tree is kept until the whole app quits.

## Why

An OpenCode app serves every session under one PID, which is `AIDEVOPS_LIFECYCLE_RUNTIME_PID = process.pid` (`.agents/plugins/opencode-aidevops/shell-env.mjs:251-252`). Two independent owner checks pin finished trees to that long-lived PID:

1. Lifecycle registry: the session's admitted run stays `bound` until the PID exits, so `prepare-cleanup` reports `waiting-for-runs` (`.agents/worker-lifecycle/worker_lifecycle/cleanup_plan.py:139-145`).
2. Legacy owner / cleanup receipt: `complete` records `owner_pid` from `_resolve_worktree_owner_pid` or `$PPID` (`.agents/scripts/full-loop-helper-state-lifecycle-commands.sh:695-702`). The merge path does the same in `_merge_record_deferred_cleanup_owner` (`.agents/scripts/full-loop-helper-merge-cleanup.sh:542-552`). Pulse removal skips while `_worktree_owner_alive` holds (`.agents/scripts/pulse-cleanup-worktree-removal-central.sh:149-155`).

GH#37432 adds `worker-registry.py relinquish-session` and wires it only into explicit `worktree-helper.sh remove`, which consults the registry alone. It does not change the `complete` handoff. Point-in-time evidence on one host (counts only), from the aidevops repo: 259 registered worktrees against a dispatch cap of 200. About 70 trees were bound to 5 live `opencode` processes, and the dispatch log reported `Live worktree count N >= cap` more than 700 times. Dispatch spawned 0 workers in a 30-minute window with free slots.

## How

- Prerequisite: t18929 (GH#37432) merged on `main`. If `relinquish-session` is absent from `.agents/worker-lifecycle/worker_lifecycle/registry.py`, stop and report blocked rather than reimplementing it.
- In `cmd_complete` (`full-loop-helper-state-lifecycle-commands.sh` ~690-735), after the receipt is durable, end this session's own registry run for the current worktree. Reuse the GH#37432 shell gate `_worker_lifecycle_relinquish_caller` in `.agents/scripts/worker-lifecycle-state.sh`, or add a small `worker_lifecycle_relinquish_session <path>` wrapper there. It needs `AIDEVOPS_LIFECYCLE_RUNTIME_PID` and `AIDEVOPS_LIFECYCLE_SESSION_ID` and must never fail the handoff.
- Make the receipt or legacy owner check accept the session's explicit end: for example, record the owner session plus a `relinquished` marker in the receipt. Then `_worktree_owner_alive`, or the receipt lease check, treats that owner as finished even though the runtime PID lives. Keep fail-closed behaviour for every other case.
- Design constraint: once the handoff relinquishes, the session must not need the tree again. Re-admission refuses with `session-owner-already-ended`, and the plugin now explains that. Document this in `.agents/workflows/full-loop.md` step 9.
- Out of scope; record a decision in the PR: trees pinned by earlier sessions of a still-running app that never ran `complete`. Ending those needs OpenCode session-liveness evidence (`aidevops_sessions list`), not PID liveness.

## Acceptance

- After `complete` in an interactive session, a Pulse cleanup pass retires the merged tree, with archive-first retirement unchanged, while the OpenCode app is still running.
- A tree whose session did not run `complete` is still retained while its runtime lives.
- Headless workers are unchanged: their runtime exits at completion.

## Verification

- `python3 -B -m unittest discover -s .agents/worker-lifecycle/tests -v` with `PYTHONPATH=.agents/worker-lifecycle`.
- Extend `.agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh` and `.agents/scripts/tests/test-worktree-cleanup-branch-merged-owned-skip.sh` (existing; no new runner).
- `shellcheck` on changed scripts.
- After release: count `Live worktree count N >= cap` lines in `~/.aidevops/logs/pulse.log` and the registered worktree count against the cap.

Ref #37432 (relinquish primitive), #37022 (caller self-binding), #37424 (release reaper starvation).

### Files Scope

- .agents/scripts/full-loop-helper-state-lifecycle-commands.sh
- .agents/scripts/full-loop-helper-merge-cleanup.sh
- .agents/scripts/full-loop-cleanup-receipt.sh
- .agents/scripts/pulse-cleanup-worktree-removal-central.sh
- .agents/scripts/worker-lifecycle-state.sh
- .agents/workflows/full-loop.md
- .agents/scripts/tests/test-full-loop-merge-worktree-cleanup.sh
- .agents/scripts/tests/test-worktree-cleanup-branch-merged-owned-skip.sh

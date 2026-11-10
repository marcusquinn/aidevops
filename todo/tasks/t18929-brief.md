## What

Let an interactive session explicitly relinquish its own lifecycle run on a worktree it has finished with. Then long-lived OpenCode app processes stop pinning merged worktrees and release checkouts until the app quits. Wire the relinquish into the owning session's explicit worktree removal.

## Why

Per-repository dispatch fails closed when live worktrees reach the cap (`pulse-dispatch-core.sh:195-214`, default 200). On one Pulse host (2026-11-09 ~19:55Z, counts only) the aidevops repo had 259 live worktrees. Every aidevops dispatch candidate was rejected at `dedup.worktree_cap`: 7 of 7 pre-launch rejections in a 30-minute window, 0 spawns, 18 free slots.

Classifying the 259 by what holds their lifecycle generation (read-only registry query):

- 68 are bound to a **live** `opencode` process: 5 distinct app processes, 16-24 h old, one holding 44. 41 of these are release tag, preparation or control checkouts that inherited the interactive runtime identity before GH#37365. The rest are interactive feature or bugfix worktrees whose PRs are typically merged.
- 15 are bound to dead PIDs with stale `alive` observations (handled by GH#37424).
- 84 have all runs ended; 77 have no generation file or no runs (legacy and observation-era classes).

Without the 68 live-process pins the repo is at 191 (<200) and dispatch reopens.

Root cause: `shell-env.mjs:251-252` declares `AIDEVOPS_LIFECYCLE_RUNTIME_PID = process.pid` (the OpenCode app process) and the session ID. `admit_session` (`worker_lifecycle/session.py`) derives `run_id` from generation, session and identity, so runs are already session-scoped. But a run only ends when the native process exits, and all sessions in one OpenCode app share that PID. Finishing, closing or rolling over a session releases nothing; only quitting the app does.

## How

1. Registry: `relinquish-session --path PATH --pid PID --session-id ID`. Recompute the run_id exactly as `admit_session` does. Require the PID to be an ancestor of the invoking process (`caller_ancestors` in `cleanup_plan.py`). Record an `ended` observation with reason `session-relinquished`. Never touch other runs of the generation. Idempotent. #aidevops:trust-boundary.
2. Callers: explicit `worktree-helper.sh remove` opts in. When retirement reports `waiting-for-caller`, relinquish the caller session's run on that path, then retry retirement once.
3. Re-admission: relinquish is permanent; a later `admit-session` by the same session refuses with `session-owner-already-ended`, and the plugin explains it.
4. Docs: CLEANUP.md documents the verb.

## Implementation note (PR #37449)

- Delivered: items 1-4. Runtime-verified in a live OpenCode session. Before the change, the deployed remove refused with `waiting-for-caller`; with it, the same tree relinquished and retired archive-first.
- Deferred: release-tree inherited bindings. The release reaper runs outside the owning runtime's process ancestry, so the ancestor gate correctly refuses there; those trees still retire when the app exits.
- Deferred to t18930 (GH#37448): the `full-loop-helper.sh complete` handoff, which also holds a legacy owner PID checked by Pulse.

## Acceptance

- A session that merged a PR can remove its own clean worktree in the same session (no "retirement completes after this session exits").
- Another session in the same OpenCode process that is still bound to the same tree keeps it retained.
- A process that is not the bound runtime (not an ancestor) cannot relinquish.
- Existing lifecycle tests pass; focused cases are added to existing test files (no new runner).

## Verification

- `PYTHONPATH=.agents/worker-lifecycle python3 -B -m unittest discover -s .agents/worker-lifecycle/tests -v` (CI entrypoint in `.github/workflows/code-quality.yml`) and `shellcheck` on touched shell files.
- Manual: in an interactive session, create a worktree, run a command in it, then run `worktree-helper.sh remove <path>`. Expect `status: retired`, not `waiting-for-caller`.
- Pulse host: `Live worktree count N >= cap` lines stop for aidevops once pins clear.

Ref #37022 (caller self-binding; caller not auto-excluded), #37365 (release executor ownership), #37424 (reaper starvation).

### Files Scope

- .agents/worker-lifecycle/worker_lifecycle/session.py
- .agents/worker-lifecycle/worker_lifecycle/registry.py
- .agents/worker-lifecycle/worker_lifecycle/cleanup_plan.py
- .agents/worker-lifecycle/worker_lifecycle/cli_errors.py
- .agents/scripts/worktree-helper.sh
- .agents/scripts/worktree-helper-cmds.sh
- .agents/scripts/worker-lifecycle-state.sh
- .agents/scripts/full-loop-release-worktree-lib.sh
- .agents/plugins/opencode-aidevops/lifecycle-admission.mjs
- .agents/worker-lifecycle/CLEANUP.md
- .agents/worker-lifecycle/tests/test_enrollment.py
- .agents/worker-lifecycle/tests/test_admission.py
- .agents/worker-lifecycle/tests/test_retirement.py

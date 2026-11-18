## What

After a `permission_required` hold re-arms (window re-arm, GH#36232), the runner whose login released that hold gives other runners the first claim for a bounded grace period before it reclaims. Before this change the re-arming runner usually reclaimed first and repeated the same denial. That opened the circuit (GH#36342 spent window) and the issue waited for a human, even though other runners completed the same task class. After the grace period the releasing runner may claim again, so single-runner installs keep the old behaviour, only later.

## Why

Recovery intake is runner-local (`terminal-blocker-recovery-helper.sh`). The runner that recorded the hold usually re-arms it and then dispatches it in its next cycles, before any peer has seen `status:available`. Evidence from a managed private repo, 2026-11-17/18:

- A consolidation task released `permission_required` on runner A (one model). The 12-hour window re-armed it on runner A at 21:24, runner A dispatched it again at 21:48, and it repeated the denial within 80 seconds. That opened the circuit (`observations=2`). An interactive session later closed the task by hand.
- All 9 currently held consolidation tasks released on runner A with the same model; 5 other consolidation tasks there completed. In a 20-task sample, every consolidation task dispatched to runners B and C completed.
- When a peer did get first claim after a re-arm, it picked the issue up within 3-10 minutes (two older holds in the same repo).

The cause of the runner-A denials stays in that runner's private telemetry. Rerouting needs no cause: one peer attempt either completes the task or produces two-runner evidence for the existing fleet hold (`terminal_blocker_fleet_hold_active`, GH#35788).

## How

- `EDIT: .agents/scripts/terminal-blocker-circuit.sh`: add `terminal_blocker_permission_peer_preference_active comments_json`. It returns 0 (and prints `TERMINAL_BLOCKER_PERMISSION_PEER_PREFERENCE retry_after=<epoch>`) when all of these hold:
  - the newest trusted hold event (observation or circuit marker) carries the `permission_required` fingerprint. Selection is shared with `terminal_blocker_permission_rearm_after` through `_terminal_blocker_newest_permission_event`;
  - its author is this runner's login (`_terminal_blocker_self_login`);
  - a `<!-- aidevops:terminal-blocker-rearmed key=` receipt follows it, authored by an OWNER/MEMBER/COLLABORATOR or this login (the set recovery accepts for replay suppression in `_tbr_project_rearm`);
  - no trusted retry directive follows the hold event;
  - now is before receipt time + `AIDEVOPS_PERMISSION_PEER_GRACE_SECONDS` (default 3600; 0 disables; read as base 10; a non-numeric value uses the default).

  Otherwise, including unreadable evidence, it returns 1. It only defers this runner, never grants anything, and adds no comments or labels.
- `EDIT: .agents/scripts/dispatch-dedup-helper.sh`: `has_dispatch_comment` calls the gate right after `terminal_blocker_circuit_active`. It does not go inside `terminal_blocker_circuit_active`, because `terminal-blocker-recovery-helper.sh` also calls that function and must not treat a dispatch-only deferral as an active hold.
- `EDIT: .agents/reference/worker-diagnostics.md`: a short paragraph beside the GH#36232/GH#36342 permission paragraph.

### Files Scope

- .agents/scripts/terminal-blocker-circuit.sh
- .agents/scripts/dispatch-dedup-helper.sh
- .agents/reference/worker-diagnostics.md
- todo/tasks/t19092-brief.md
- TODO.md

## Acceptance Criteria

- [ ] The releasing login skips a re-armed `permission_required` issue for the grace period; other logins are not deferred.
- [ ] The deferral ends after the grace period, after a trusted retry directive that follows the hold, or when the newest hold event is not `permission_required` or belongs to another login.
- [ ] Holds without a re-arm receipt keep their existing behaviour (this gate returns 1).
- [ ] `test-terminal-blocker-circuit.sh` and `test-dispatch-lifecycle-comms.sh` pass; ShellCheck is clean.

## Verification

- `bash .agents/scripts/tests/test-terminal-blocker-circuit.sh`
- `bash .agents/scripts/tests/test-dispatch-lifecycle-comms.sh`
- `shellcheck .agents/scripts/terminal-blocker-circuit.sh .agents/scripts/dispatch-dedup-helper.sh`
- Ad hoc: source `terminal-blocker-circuit.sh` and call `terminal_blocker_permission_peer_preference_active` with fixture comments covering self in grace, peer, expired grace, grace 0, custom grace, no login, no receipt, receipt before hold, non-permission class, retry after hold, newer peer hold, and malformed input.

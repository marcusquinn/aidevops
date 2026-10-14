<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Pulse maintenance and worker launch contracts

## Maintenance checkpoints

`pulse-dispatch-engine.sh` records a housekeeping checkpoint only when its
command returns zero and the budget adapter has not deferred execution.
The resumable stage adapter returns zero for completed or recently checkpointed
work and one for incomplete work. The coordinator aggregates these results;
independent stages continue, and maintenance never blocks dispatch on failure.

A partially successful run keeps successful checkpoints for the existing resume
window. A fully successful run removes them. Failed, timed-out, interrupted and
budget-deferred stages remain eligible for the next invocation, not an immediate
retry loop. Blocker catch-up stops after a failed/deferred prerequisite instead
of using an unrefreshed dependency graph.

This is not an exactly-once execution guarantee: checkpoint persistence remains
best-effort, checkpoints expire, and individual stage implementations must retain
their existing idempotency protections. A command that internally suppresses its
own failure cannot be classified correctly by its caller.

## Worker lifecycle backend

`AIDEVOPS_WORKER_BACKEND` selects one lifecycle owner before launch:

| Value | Behavior |
| --- | --- |
| `auto` (default) | Select systemd on Linux when systemd host/service evidence or a reachable user manager exists; otherwise use the portable detached path. |
| `systemd` | Require a reachable Linux user manager; never fall back after failure. |
| `detached` | Explicitly use the existing setsid/nohup path, with its weaker lifecycle guarantees. |

In `auto`, the legacy `AIDEVOPS_SKIP_SYSTEMD_WORKER_SERVICE=1` explicitly selects
`detached`. An explicit backend takes precedence. Invalid values reject launch.
Configure environment values in the existing supervisor environment; this change
does not rewrite or restart installed scheduler units.

Manager reachability uses a manager property query, not health of unrelated
units. A degraded manager can still be reachable. Once systemd is selected,
manager unavailability, submission failure, missing PID or unconfirmed readiness
must not trigger another backend. The unit identity is saved before submission
in the existing worker-log `.systemd-launch` sidecar for diagnosis.

An ambiguous response is not proof that a worker is absent. Retaining the unit
identity and suppressing fallback prevents a duplicate within this invocation;
durable reconciliation across future dispatch attempts is a separate concern.

User services provide cgroup lifecycle ownership, not a security sandbox. This
contract adds no sudo privileges and does not change approval signing, host
provisioning or the optional privileged worktree inspector.

## Focused verification

Run from the repository root; launch tests substitute systemd commands rather
than starting real worker services:

```bash
bash .agents/scripts/tests/test-pulse-post-dispatch-housekeeping.sh
bash .agents/scripts/tests/test-pulse-dispatch-stage-rc-adapter.sh
bash .agents/scripts/tests/test-pulse-dispatch-engine-stage-wiring.sh
bash tests/test-systemd-worker-service-launch.sh
bash .agents/scripts/tests/test-pulse-dispatch-worker-launch-lock.sh
bash .agents/scripts/tests/test-pulse-systemd-timeout.sh
bash .agents/scripts/tests/test-pulse-cycle-state-contract.sh
```

Run ShellCheck on changed shell files and `git diff --check` before delivery.

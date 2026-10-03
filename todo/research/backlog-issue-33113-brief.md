## What

Recover regression #33113 of #32546: old-bundle worker-exit Pulse refills can
respawn during setup reconciliation, acquire the shared instance lock, and
prevent a newly activated bundle from starting.

## Observed evidence

On 2026-09-30, setup stopped pre-reconciliation Pulse processes and launchd
accepted a restart, but no new activated-bundle process appeared. Refill-only
processes from the previous bundle kept appearing with
`--refill-source=worker-exit`; the new launchd Pulse then lost its instance lock.
This is historical evidence: verify the current owning path before changing it.

## Approach and boundaries

Follow the worker-exit refill entry through runtime pinning and the setup
reconciliation helper. Prefer fixing the entry boundary so an old worker starts
its refill from the verified active bundle before lease/instance-lock acquisition.
Preserve ordinary invocation pinning, missing/invalid active-root failures,
process identity checks, bounded replacement proofs and managed launchd ownership.
Do not accept an arbitrary refill lock as activation evidence, disable guards,
kill unrelated processes, or weaken worktree/source permissions.

### Files Scope

- EDIT if needed: `.agents/scripts/pulse-wrapper.sh`
- EDIT if needed: `.agents/scripts/pulse-runtime-pin.sh`
- EDIT if needed: `.agents/scripts/pulse-lifecycle-helper.sh`
- Existing tests: `.agents/scripts/tests/test-pulse-lifecycle-helper.sh`
- Existing tests: `.agents/scripts/tests/test-pulse-event-refill.sh`
- Existing tests: `.agents/scripts/tests/test-pulse-runtime-pin.sh`
- Exact fix/test placement is not yet known; establish it by tracing the entry.
- Hard boundary for concurrent mission unit #33303: do not edit
  `headless-runtime-lib.sh`, `headless-runtime-worker.sh`, manual-dispatch or
  pre-edit ownership code. Return a serialization need if that boundary is needed.

## Acceptance and verification

- Reproduce activation B while a worker pinned to A requests its exit refill;
  the request uses B before taking the lock, or current code is proven to do so.
- Setup reconciliation observes a newly started active-bundle managed process
  and returns success; old-bundle refills cannot continuously win the lock.
- Current-bundle, sourced/test invocation, invalid active root and unrelated-owner
  negative paths retain their existing behavior.
- Exercise the normal CLI/process paths in isolated existing fixtures, run both
  existing suites, syntax, ShellCheck and changed-file lint. High-risk lifecycle
  work requires runtime evidence and independent closeout review.
- Never activate or terminate unrelated production services to construct a test.

## Dispatch authority

The repository owner authorized this unattended backlog mission, with at most
two independent mission workers. This thinking-tier self-hosting unit is independent of the
manual-worker ownership repair; parent owns integration, issue disposition and
the explicitly authorized final release. If the premise is already fixed,
return exact merged-fix/runtime evidence instead of a speculative patch.

[effort:thinking] Implement and verify within this scope, then push a ready PR
and return exact-head evidence to the parent. Do not merge, release, edit shared
mission planning, or delegate again. Parent performs integration and closeout.

<!-- aidevops:origin:interactive -->

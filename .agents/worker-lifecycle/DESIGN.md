---
description: Portable worker lifecycle replacement design and observe-only acceptance contract
status: proposed
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Worker Lifecycle

## Decision and scope

Build a replacement, not another permanent authority alongside the current
worktree lifecycle. Ship Linux first, with a portable core and a later macOS
adapter, entirely in user space, with a structurally non-destructive observe-only
implementation. This document specifies intended behavior;
it does not claim implementation, deployment, or proven reliability.

The replacement owns worker-run lifecycle tracking, worktree-generation bindings,
reconciliation, and eventually admission to cleanup. Archive and removal remain
separate executors. Neither executor independently guesses worker liveness.

Observe-only mode may write only its private database and bounded diagnostics. It must
not update the old registry, acquire real worktree ownership, create or remove
worktrees, signal processes, archive data, or authorize deletion. Initially there
is no executor implementation or switch that enables destructive behavior.

## Architecture

One Python package, one CLI, one private SQLite database on a local filesystem.
Use the Python standard library, with thin native OS adapters and no psutil
dependency. No broker, network service, privileged
agent, microservices, or collection of Bash helpers. Existing launchers may call
one thin adapter; lifecycle rules reside only in the package.

Logical modules: domain transitions, transactional storage, platform observations,
event ingestion/reconciliation, and CLI reporting. These are modules, not services.
Prefer short bounded invocations initially; add a persistent monitor only after
measuring a need. Different hosts have independent authorities in v1; a shared
network SQLite file and cross-host ownership are unsupported.

Keep design, implementation and tests under `.agents/worker-lifecycle/`. The
Python package is `worker_lifecycle`; avoid version suffixes and new modules in
the legacy scripts directory. Integration and deployment are explicit later
steps, not implied by placing this directory in the repository.

### Portability boundary

Domain transitions, persistence, ingestion and reports must not import Linux
adapters or interpret procfs fields. Select a platform adapter explicitly at the
application boundary. Unsupported platforms return an actionable unsupported
result, never a Linux fallback or an empty process list.

The adapter contract captures a versioned process identity and observes it as
`alive`, `ended`, or `unknown`, with a reason and sampling context. Identity has
portable fields (installation, platform, boot generation, PID, process-generation
token, user identity) and adapter-specific evidence. Tokens are opaque outside
their adapter; Linux start ticks are not a portable timestamp. Observations from
another installation, platform, or unsupported evidence version remain unknown.

| Capability | Linux first | macOS later |
|------------|-------------|-------------|
| Process generation | procfs starttime plus boot identity | `proc_pidinfo()` start metadata and `kern.bootsessionuuid`; native ABI and availability to verify |
| Optional live notification | pidfd when available | Native notification if justified; not required by the core |
| Persistent state | Local SQLite | Local SQLite with platform durability settings verified |
| Scheduling | External user-space invocation | External user-space invocation; no systemd dependency in core |
| No-writers evidence | Separate execution contract, not PID death | Separate execution contract; no assumed cgroup equivalent |

Do not implement speculative macOS native calls now. Before declaring support,
verify native API access without administrator rights, process-generation and
reboot semantics, sleep/wake timing, SQLite flush behavior (including fullfsync
where appropriate), and filesystem identity/path semantics. Run the same domain
contract tests on both systems plus native adapter tests on each actual platform.
Mocked macOS results on Linux are not macOS support evidence.

The first implementation slice is read-only process observation, not a deployed
lifecycle authority. See [PROTOCOL.md](PROTOCOL.md) for its precise contract and
[README.md](README.md) for executable commands and current limitations.

## Trust and failure model

Processes crash, events repeat or arrive late, observations race, disks fill,
clocks change, and the machine reboots. The observer can stop for an arbitrary
period. SQLite durability depends on a functioning local filesystem and honest
storage flushes; this is not protection against media loss or malicious same-user
processes. Database corruption or I/O errors must not become empty-success state.

PID absence proves only the saved process generation ended. An expired lease or
heartbeat proves neither process death nor loss of filesystem access. A fencing
number in a database cannot fence arbitrary file writes by an old process.

## Domain model

| Entity | Identity and meaning |
|--------|----------------------|
| Worktree generation | Opaque generation ID for one physical incarnation; a reused path is not the same generation |
| Run | Opaque run ID for one worker job, independent of PID and AI-runtime retries |
| Binding | Run-to-generation relationship, with a monotonic ownership epoch for protocol ordering |

Process evidence binds a run to installation identity, platform, boot generation,
PID, process-generation token and user identity. On Linux these include boot ID,
starttime and UID in a known proc/PID-namespace context. Cross-namespace identity
is unsupported until explicitly designed. Do not persist prompts, environment
variables, credentials, or raw process command lines.

The worker-job supervisor is distinct from an individual OpenCode invocation.
Capture identity at the controlled worker entrypoint, not by guessing from a
process name or PPID. Do not invent identities for runs missed by the observer.

## Facts, observations, and decisions

Keep these separate:

1. Launcher facts: run reserved, identity bound, worktree bound, exit reported.
2. Kernel observations: exact process alive, absent, reused, previous boot, unknown.
3. Derived run state, including evidence references and observation freshness.
4. Hypothetical cleanup eligibility, including every unresolved prerequisite.

An exit report is not proof that all worktree writers have stopped. Unknown is an
observation result, not a destructive state transition. Retain the last confirmed
fact when a new observation is unavailable.

## State machines

| Run state | Transition and precondition |
|-----------|-----------------------------|
| Reserved | Durable run intent exists; process identity may not yet be known |
| Bound | Verified process identity has been attached to this run |
| Ended | Exact recorded process ended, with stable evidence; terminal for this run ID |
| Cancelled | Admission was closed before work began; only valid under a protocol preventing delayed admission |

Missing identity does not allow reserved-to-ended inference. In observe-only mode,
missed or uncertain admission stays explicitly unresolved. Duplicate events are
no-ops only when their payloads match; conflicting reuse of an event ID is an error.
An ended run never becomes bound again; a retry gets a new run ID.

Worktree generation has a separate lifecycle: open, closing, sealed, retired.
Future active mode must atomically close admission before checking quiescence.
Sealing requires all admitted runs tracked and an enforceable no-writers
contract. Retirement belongs after the archive/removal executor's verified
receipt, not after observing a dead PID. Observe-only mode only predicts these changes.

## Persistence and concurrency

Persist a minimal event journal and its materialized state in the same SQLite
transaction. This is not a general-purpose event-sourcing platform. Each event
has schema version, event ID, run/generation identity, type and bounded payload.
Acknowledgement follows commit. A caller retry uses the same event ID.

Use schema migrations, foreign keys, uniqueness constraints and conditional
updates against expected versions. Serialize writes with short transactions and
a bounded busy timeout. Never hold a write transaction across process sampling,
Git commands or other slow operations. Recheck record versions before committing
sampled evidence; outdated samples do not authorize a transition.

Use WAL and FULL synchronous durability only on a supported local filesystem;
configure both explicitly and verify the effective settings. State directories
are private to the user. Initialization must not replace an existing or corrupt
database. Unsupported schema versions fail closed.

Use monotonic time within a boot for deadlines; wall time is for diagnostics,
not proof of termination. Define suspend/resume behavior per adapter; elapsed
time alone never proves death. Reboot invalidates monotonic deadlines. Bound journal
growth with documented retention/checkpoint rules that preserve terminal evidence
and idempotency guarantees; do not silently discard deduplication history.

## Linux observation

Read only the recorded PIDs from procfs. Compare boot, PID, starttime and UID;
sample defensively against exit/reuse races. A readable matching process is alive.
Confirmed absence, replacement, or a boot transition ends that recorded process.
Unavailable procfs, permission errors, malformed data and ambiguous races remain
unknown. Recheck context before accepting negative evidence.

Use pidfd where available for in-process monitoring, not as a persistent identity
or a requirement for restart recovery. A pidfd does not establish descendant
quiescence. Define zombie handling explicitly before implementation acceptance.

No full-machine CWD scan, worktree content walk, Git call, or subprocess per PID
belongs in the normal reconciliation path. Terminal runs are not polled again.
Reconciliation is indexed, batched, resumable and bounded by time and count.

## Observe-only integration

Stage A is an isolated kernel receiving explicit events and sampled identities.
Stage B adds best-effort events at existing controlled launch/bind/exit boundaries.
Registry failures must not block the old execution path, but must be visible as
coverage gaps. Do not promise complete capture without durable producer delivery.
Sampling alone can miss a short-lived run entirely.

Read-only imports of legacy records retain their origin and uncertainty; they are
not native admission facts. Missing historical provenance cannot be reconstructed
as a successful admission. Keep existing worktree generations on the old authority
unless an explicit migration establishes their new contract.

## Failure acceptance matrix

| Fault | Required result |
|-------|-----------------|
| Crash before transaction commit | No partial event/state update |
| Crash after commit before acknowledgement | Retry returns the already committed result |
| Duplicate or reordered events | No duplicate binding, resurrection, or overwritten newer fact |
| Concurrent claim/reconcile | One valid version transition; conflicts retry or defer |
| Worker exits without final event | Kernel reconciliation ends its recorded run |
| PID reuse or reboot | No attribution to the replacement process |
| Inaccessible procfs | Unknown with reason and bounded retry |
| Database busy, full, unavailable or corrupt | Explicit failed/deferred lifecycle tracking; no false success |
| Observer restart | Continue from durable state without resetting identities |
| Missed launcher event | Report incomplete coverage, never fabricate provenance |
| Dead parent with surviving child | No claim that the worktree has no writers |
| Late old owner after timeout | Timeout alone grants neither replacement nor cleanup authority |

## Promotion and replacement

1. Observe-only lifecycle tracking with zero worktree/process mutations.
2. Fault injection and comparison against independently verified outcomes;
   disagreement with the old system is not automatically a new-system defect.
3. Explicit canary authority for selected NEW generations only.
4. Expansion after safety, recovery, coverage and latency gates pass.
5. Drain legacy generations, disable and then remove superseded code.

Exactly one subsystem controls a generation. Record authority routing explicitly.
Rollback must quiesce the new authority and reconcile its admitted runs before
handoff; an application flag alone is not a safe ownership rollback.

Before active promotion, specify and prove the worker execution/containment
contract that prevents surviving or stale writers. This is an open design gate,
not solved by lifecycle tracking, a lease, or a saved process ID.

## Delivery slices and measurements

1. Review this protocol and enumerate state-transition preconditions.
2. Implement isolated storage, ingestion, Linux observation and JSON status in one
   package/CLI; no scheduler, old-system mutation or executor.
3. Exercise crash/replay/concurrency cases with existing test tooling and isolated
   fixtures; record results rather than claiming reliability from uptime.
4. Add explicit registry launch events, coverage diagnostics and bounded scheduling.
5. Measure before choosing canary scope or promotion thresholds.

Track reconciliation p50/p95, process reads per pass, transaction latency/busy
rate, unprocessed-event age, unknown reasons, coverage gaps, recovery time, journal
growth, and hypothetical unsafe cleanup decisions. Establish numerical budgets
on this host before canary promotion. Routine work must scale with due unfinished
runs, not all historical runs or the size of worktree contents.

Acceptance requires both safety (no unjustified cleanup eligibility in the fault
matrix) and progress (ended runs converge after observations become available).
No claim of active-mode readiness is allowed until the no-writers contract,
legacy migration, rollback and retention protocols are verified.

---
description: Ownership, safety classes, lifecycle contracts, and convergence rules for aidevops-managed storage
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Storage Lifecycle Architecture

This document defines the framework boundary for diagnosing and bounding data
created during aidevops operation. It is an architecture contract, not authority
to delete data. Store-specific helpers remain responsible for proving that an
artifact is reclaimable before any mutation.

## Design Goals

- Make framework-owned growth measurable and convergent under normal use.
- Preserve active sessions, runtime leases, rollback state, worker recovery,
  and required audit evidence regardless of configured soft limits.
- Distinguish protected, recoverable, cache, and disposable bytes in one
  read-only operator view before adding aggregate cleanup.
- Keep third-party stores visible when useful without claiming ownership or
  deleting data that aidevops cannot classify safely.
- Give leak fixes a conservative, attributable migration path for leftovers.

## Ownership Classes

| Class | Meaning | Allowed framework action |
|---|---|---|
| `framework` | Created and exclusively managed by aidevops | Report, archive, and prune under the store contract |
| `joint` | Aidevops writes or coordinates data owned by a host runtime | Report known components; mutate only through a runtime-aware contract |
| `external` | Package-manager, browser, OS, or user-owned data | Report as context only; never include in automatic reclamation |
| `unknown` | Attribution cannot be proved | Report separately and fail closed |

Path location alone never establishes ownership. For example, an npm cache may
grow because bundle installation used it, but it remains external unless the
package manager provides a scoped and safe cleanup contract.

## Safety Classes

Every reported artifact must have one safety class. When evidence overlaps, the
most protective class wins.

| Class | Examples | Default lifecycle |
|---|---|---|
| `active` | Current bundle, active OpenCode DB/WAL, live session files | Never reclaim |
| `leased` | Runtime bundle with a live process lease | Never reclaim while the lease is valid |
| `rollback` | Previous runtime bundle, most recent deploy snapshot | Retain until a newer rollback point is verified |
| `recovery` | Worker recovery DB, dirty-worktree backup, pending replay data | Retain until terminal state and recovery verification |
| `audit` | Required lifecycle/error evidence and signed operation records | Retain or compact only under an explicit audit contract |
| `archive` | Deliberately retained historical data | Apply documented age/count/byte policy; deletion remains explicit |
| `cache` | Reproducible dependencies, indexes, derived reports | Reclaim after proving no active reference |
| `scratch` | Attributable temporary files with no live owner | Reclaim after owner-death and age checks |
| `unknown` | Unclassified files or ambiguous references | Never reclaim automatically |

Age, count, or byte thresholds are soft limits: they select candidates only.
Reference, lease, recovery, and audit checks remain hard vetoes.

## Initial Store Inventory

| Store | Owner | Primary classes | Existing authority | Required next contract |
|---|---|---|---|---|
| `~/.aidevops/runtime-bundles` | framework | active, leased, rollback, cache | Deployment protects current, previous, and live-leased bundles; unreferenced bundles converge under 30-day, 30-bundle, and 8 GiB soft limits | Keep the limits operator-configurable and preserve fail-closed reporting when references or sizing are unavailable |
| `~/.aidevops/.agent-workspace/observability` | framework | audit, archive, cache | Runtime events are append-only evidence; plugin records runtime and tool-call data | Define the minimum audit envelope, payload/metadata limits, partition or archive semantics, and verified compaction rather than direct row deletion |
| `~/.aidevops/agents-backups` | framework | rollback, archive | Count-based snapshot retention | Add byte/age reporting and preserve at least the newest verified rollback artifact |
| `~/.aidevops/logs` and worker failure excerpts | framework | audit, archive, scratch | Individual excerpts are size-capped; policies vary by producer | Define producer ownership and combined age/count/byte retention while retaining terminal failure evidence |
| OpenCode data under its application-data root | joint | active, recovery, archive, unknown | OpenCode owns session and DB formats; aidevops archive/maintenance helpers coordinate selected operations | Separate logical retention from WAL/fragmentation maintenance; report only classifications proven through OpenCode-aware queries |
| npm and other package-manager caches | external | cache | Package manager owns lifecycle | Context-only reporting; no aidevops aggregate deletion |
| OS temporary and Trash locations | external or joint | scratch, unknown | OS/runtime-specific | Reclaim only aidevops-attributable artifacts through an owner-aware migration; never broad-clean a directory |

The inventory is intentionally conservative. A child implementation may split a
row when one path contains artifacts with different owners or safety classes.

### Runtime Bundle Dependency Decision

Runtime activation continues to verify the OpenCode host's existing dependency
tree first and installs declared dependencies inside a staged bundle only when
that verification fails. A new lock-keyed shared dependency store is deferred:
it would introduce shared mutable ownership, concurrent-install locking, cache
integrity, and offline rollback dependencies into otherwise immutable bundles.
The measured duplication is instead bounded by pruning unreferenced bundles.
This preserves atomic activation and makes each retained rollback bundle
self-verifying without making npm's global cache framework-owned.

## Store Lifecycle Contract

Each framework-owned store must eventually publish the following information to
a shared read-only reporting surface:

1. Stable store and producer identifiers.
2. Root path or runtime-aware query used for inventory.
3. Ownership class and rationale.
4. Artifact safety class and the evidence that established it.
5. Total, protected, reclaimable, and unknown byte counts.
6. Existing age/count/byte limits and the next evaluation time, where relevant.
7. Protection reasons such as current target, previous target, live lease,
   active session, pending replay, or audit requirement.
8. Dry-run candidate details and a store-specific cleanup command, if one exists.
9. Migration marker or version when a fixed leak leaves attributable leftovers.

Inventory failures must leave artifacts `unknown`; they must not turn an
unreadable or unavailable reference into a reclaimable candidate.

## Convergence Contract

A store is bounded when a synthetic steady workload reaches a stable envelope
after its retention window while protected references remain unchanged.
Convergence tests must specify workload, elapsed policy time, protected set,
candidate set, and measured bytes. A passing test demonstrates all of these:

- unreferenced framework-owned artifacts eventually fall within the selected
  age/count/byte policy;
- exceeding a soft limit does not remove active, leased, rollback, recovery, or
  required audit artifacts;
- a failed ownership/reference query produces unknown bytes and no deletion;
- repeated dry runs are idempotent and explain the same candidate decisions;
- cleanup interruption is recoverable or leaves the original artifact intact;
- Linux and macOS fixtures make the same policy decision without relying on
  GNU-only filesystem output.

Defaults should be selected from measurements across both routine and
high-activity installations. Until that evidence exists, implementations may
add reporting and opt-in limits but must not infer aggressive defaults from one
installation.

## Operator Surface

The first cross-store feature is a read-only report, integrated into an existing
status or maintenance path unless implementation evidence justifies a new
command. It should show:

- store, producer, owner, safety class, and policy;
- total, protected, reclaimable, and unknown bytes;
- the exact reason protected data is not reclaimable;
- whether sizing is exact, sampled, estimated, or unavailable;
- a non-destructive next action owned by the responsible subsystem.

Aggregate cleanup is explicitly deferred. A future coordinator may invoke
store-specific dry-run/apply contracts, but it must not implement a generic
filesystem age or size deletion loop.

## Implementation Sequence

1. Build the shared read-only inventory/report contract and fixtures.
2. Bound runtime bundles and evaluate lock-keyed dependency reuse while retaining
   current, previous, and live-leased protections.
3. Define observability audit retention, payload limits, and archival or
   partitioning semantics before compacting append-only evidence.
4. Add coordinated policies for framework backups, logs, and worker failure
   excerpts, including conservative leftover migration.
5. Coordinate OpenCode-owned storage through runtime-aware reporting and
   maintenance; keep logical session deletion out of framework cleanup.

These are separate child tasks. The parent architecture issue remains open until
the accepted child set is complete or explicitly re-scoped by a maintainer.

## Non-Goals

- A generic disk cleaner or recursive home-directory scanner.
- Automatic deletion of OpenCode sessions or unknown runtime data.
- Limits that override leases, rollback, recovery, or audit invariants.
- Making aidevops responsible for npm, uv, Playwright, browser, or OS caches.
- Content-addressed dependency storage before measurements show that its
  complexity is justified.

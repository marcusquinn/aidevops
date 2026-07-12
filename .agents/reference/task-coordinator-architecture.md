<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Task Coordinator Architecture

Status: accepted for implementation by cryptographic maintainer approval on 2026-07-12. This decision defines contracts only; it does not enable new task identifiers or migrate existing records.

## Decision

Every newly coordinated task will have an immutable identifier composed of an
opaque installation origin and a sequence allocated by that origin. Repositories,
forge objects, issues, aliases, and local paths are mappings around that identity;
none of them defines it.

The canonical forms use this structural grammar:

```text
legacy-task-id     = "t" sequence *("." subtask)
namespaced-task-id = "t" origin "-" sequence *("." subtask)
origin             = "o" crockford-128
sequence           = positive-decimal
subtask            = positive-decimal
```

`crockford-128` is the canonical lowercase, 26-character Crockford Base32
encoding of 128 random bits. It excludes `i`, `l`, `o`, and `u`; its first
character is `0` through `7`. Decimal components have no sign or leading zero.
Each decimal component contains 1 through 18 digits and is handled as a decimal
string at codec boundaries. A task may have at most eight subtask components,
and the complete token may contain at most 199 ASCII bytes.

These POSIX EREs are the authoritative lexical contract:

```text
legacy:     ^t[1-9][0-9]{0,17}(\.[1-9][0-9]{0,17}){0,8}$
namespaced: ^to[0-7][0-9a-hjkmnp-tv-z]{25}-[1-9][0-9]{0,17}(\.[1-9][0-9]{0,17}){0,8}$
```

Examples:

```text
t18097
t18097.2.1
to01j2abc3def4gh5jkm6npq7rst-42
to01j2abc3def4gh5jkm6npq7rst-42.3
```

The `t` prefix preserves task-token recognition. The hyphen unambiguously
separates origin from its local sequence, while dots remain hierarchy markers.
The format is safe in Git refs, filenames, CLI arguments, TODO lines, issue and
PR titles, logs, and forge metadata. Case folding, abbreviation, alternate
alphabets, and omitted origin components are not canonical.

Existing `tNNN[.N...]` identifiers remain valid indefinitely. They are legacy
identities, not aliases that may be silently rebound to namespaced tasks.

## Terminology

- **Installation origin**: an opaque namespace owned by one coordinator state
  lineage. It identifies where a sequence was allocated, not a person, device,
  repository, forge, or Git remote.
- **Canonical task token**: a legacy or namespaced token accepted by the shared
  task identity codec. A namespaced token is globally self-identifying. A
  legacy token requires its verified home repository identity to resolve a
  task.
- **Task mapping**: an explicit relationship between a canonical task and a
  repository, issue, PR, brief, projection, or external system.
- **Operation**: an idempotent requested coordinator state transition.
- **Projection**: a derived representation such as a TODO line, brief marker,
  issue field, label, or comment.
- **Session provenance**: existing `origin:interactive`, `origin:worker`, and
  `origin:worker-takeover` labels. These labels never identify an installation
  origin or grant authority.

## Installation origin lifecycle

### Creation and storage

An installation creates its origin from an operating-system CSPRNG. The value
must not be derived from a username, email address, hostname, device serial,
repository, MAC address, forge account, or clock. The origin is public identity,
not a secret or authentication credential.

The coordinator stores the origin, sequence high-water mark, schema version,
and recovery evidence together in machine-local durable state. Allocation must
not read or write a repository checkout. Backups preserve the complete state
lineage rather than copying the origin token alone.

### Continuity and reinstall

Restoring an origin for further allocation is allowed only when all of these
are available:

1. a verified coordinator backup;
2. its sequence high-water mark and integrity metadata;
3. reconciliation with all known published operations for that origin;
4. an atomic compare-and-swap in the configured origin registry against the
   prior ownership epoch and fencing token;
5. the signed transfer record, new monotonically increasing ownership epoch,
   and fencing token returned to the single compare-and-swap winner; and
6. registry-authoritative evidence that the prior ownership epoch is explicitly
   revoked or expired, without relying on a restorer's local clock.

The restored allocator advances beyond the maximum local, backup, outbox, and
published sequence before creating another task. The origin registry may be a
protected forge record or encrypted personal coordination store, but it must be
shared by every installation allowed to restore that origin. Without such a
registry, restoration is read-only and the installation mints a new origin for
allocation. It must never infer exclusivity from a missing process, guess a
counter, copy another active installation's origin, or reuse a retired origin.
Registries without atomic conditional updates cannot authorize restoration.

Repository clone, fork, rename, transfer, or worktree creation does not copy or
change installation identity. Multiple machines normally have distinct origins,
even when they use the same forge login or repositories.

### States

| State | Allocation | Reads | Mutation |
|---|---:|---:|---:|
| `active` | Yes | Yes | Yes |
| `read-only` | No | Yes | Reconciliation only |
| `redirected` | No | Yes | Append redirect evidence only |
| `retired` | No | Yes | No |
| `quarantined` | No | Yes | Explicit recovery only |

Origin state transitions are append-only and audited. Redirects transfer only
administrative and lifecycle responsibility: existing tasks retain their
original origin and canonical token. Redirect chains must resolve to exactly
one active or retired lineage and reject cycles. Quarantine is mandatory for a
duplicate-origin observation, counter regression, conflicting operation, or
repository-mapping ambiguity.

## Allocation and hierarchy

The machine-local coordinator serializes top-level sequence allocation in a
transaction. Sequences increase monotonically within one origin; gaps are valid
and allocated numbers are never recycled. Allocation is available offline and
requires neither a forge call nor a canonical checkout.

Subtask identifiers extend an existing task ID. Their final component is
allocated transactionally within the parent identity and is never inferred from
the current contents of `TODO.md`. A task and each subtask are independently
addressable records while retaining their parent relationship.

Allocation and publication are separate operations. A successful allocation may
remain local and unpublished; retrying publication must use the same task ID.
Failure to create an issue must never allocate a replacement identity.

## Repository and forge mappings

A task has one immutable **home repository identity** once published. It may
also have implementation, upstream, deployment, or documentation repository
relationships. A relationship cannot overwrite the home mapping.

Repository identity is:

```text
(forge-instance-id, forge-repository-object-id)
```

- `forge-instance-id` identifies the forge authority, not merely its product
  name.
- `forge-repository-object-id` is the immutable object ID returned by that
  forge when available.
- Slugs, owner names, remote URLs, remote names, and local paths are mutable
  aliases with validity intervals.
- A forge adapter must document object-ID behavior across rename, transfer,
  restore, export, and import.
- When no stable object ID exists, the mapping is degraded and any alias change
  requires explicit maintainer confirmation.

Issue identity is `(repository identity, forge issue object ID)`. A display
number such as `#42` is valid only inside its verified repository context.
Bindings are append-only, repository-bound, and one-to-one for their validity
interval. Identical issue numbers in different repositories never collide.

Two active origins may allocate tasks for the same repository. They must not
claim the same task, issue, operation, or legacy identity mapping. Repository
membership therefore does not substitute for installation namespace.

## Authority by concern

No single representation is authoritative for every concern:

| Concern | Authority |
|---|---|
| Task identity and immutable relationships | Coordinator record plus published identity marker |
| Origin sequence allocation | Machine-local transactional coordinator |
| Repository and issue binding | Verified forge object IDs plus coordinator mapping |
| Distributed claim and dispatch state | Forge state and fenced operation evidence |
| Offline work intent | Local coordinator record pending reconciliation |
| Projection content | Coordinator state; projections are derived views |
| Completion | Verified merge, deployment, or explicit verification evidence |
| Audit | Append-only operation and result records |

An offline claim cannot silently supersede newer distributed claim evidence.
Reconciliation either proves the operations compatible or records a conflict
that blocks destructive transitions.

## Identity codec contract

All production readers and writers use one shared parser, validator, formatter,
and regular-expression contract. Callers consume structured fields rather than
re-parsing text:

```text
kind=legacy|namespaced
canonical_id=<full validated value>
origin_id=<empty for legacy, otherwise o...>
sequence=<positive decimal>
subtask_path=<empty or dot-separated positive decimals>
parent_id=<empty for top level, otherwise canonical parent>
```

The formatter must round-trip every accepted input to exactly one canonical
output. Invalid, oversized, path-like, case-variant, signed, zero, whitespace,
control-character, or shell-metacharacter forms fail before interpolation into
paths, regexes, shell commands, SQL, logs, or API requests.

During migration, external input containing a bare legacy ID may resolve only
with exactly one explicit, verified home repository context. A caller already
holding a persisted coordinator record is dereferencing that record, not
resolving a bare token. Global scans, current working directory, title-only
search, and a Git remote guessed from the process directory are not identity
context. Missing or ambiguous repository context fails closed.

## Operation and replay contract

Every mutating coordinator request carries an envelope equivalent to:

```json
{
  "operation_id": "uuidv7",
  "kind": "task.create",
  "task_id": "to01j2abc3def4gh5jkm6npq7rst-42",
  "expected_revision": 0,
  "actor_id": "verified-principal-or-installation",
  "issued_at": "2026-07-12T00:00:00Z",
  "payload_hash": "sha256:<digest>",
  "payload": {}
}
```

Delivery is at least once; exactly-once execution is not promised. The same
operation ID and payload hash returns the recorded result. Reusing an operation
ID with different content is a hard conflict. External API timeouts require
read-after-write reconciliation by canonical marker before another object is
created.

Claims and leases carry monotonically increasing fencing tokens. A stale actor
cannot mutate or release state protected by a newer token. Completion is
monotonic and requires evidence. Dry-run performs no allocation, counter change,
operation write, projection, marker, or external mutation.

Each operation reaches one durable result:

- `published`: effect and immutable evidence recorded;
- `retryable`: no contradictory effect, with bounded retry metadata;
- `indeterminate`: an external effect may exist; another create is forbidden
  until read-after-write reconciliation proves the outcome;
- `terminal`: rejected with evidence and no silent partial success; or
- `conflict`: preserved for explicit reconciliation.

## Projection and canonical-checkout boundary

TODO files, briefs, issue text, comments, and labels are projections. Automation
publishes repository projections through the serialized publication stream and
Git plumbing or a fenced automation workspace. It does not use a human canonical
checkout as a transaction buffer.

Task allocation, issue synchronization, pulse, release, update, setup, and
cleanup must leave the canonical resolved HEAD commit, index, tracked files,
untracked and ignored payload bytes, file modes, file types, symlink targets,
and directory inventory byte-identical, whether that checkout is clean, dirty,
stale, or contains human work. Automation must not update a shared ref in Git
common state when that update would move the canonical checkout indirectly.
Canonical maintenance is diagnostic-only unless a process owns an explicit
fenced automation workspace.

The protected canonical ref set is the canonical checkout's `HEAD`, its symbolic
target, and any ref whose update would change that checkout's resolved commit.
Publication-owned temporary or private refs may change when they cannot move a
human checkout and are removed or retained according to their audited lifecycle.

Runtime locks, temporary indexes, journals, databases, ready tokens, and backup
manifests live outside every worktree namespace. A stable lock inode required by
`flock` belongs in Git common state or fenced runtime state, not beside a tracked
or untracked project file.

Before any recovery decision, dirty state is preserved in a content-addressed,
verified backup with source status, tracked and staged patches, untracked payload
inventory, hashes, task/session ownership, and retention state. Unresolved or
unacknowledged incident backups cannot be pruned. Missing preservation evidence
is a failure, never proof that no work was lost.

## Compatibility and migration

Migration is additive and gated by phase:

1. **Contract and inventory**: approve this ADR; inventory numeric-only parsers,
   writers, filenames, titles, branch rules, mappings, and tests. No behavior
   change.
2. **Dual-read codec**: accept legacy and namespaced forms through the shared
   codec. Continue emitting legacy IDs only.
3. **Consumer migration**: require structured identity fields in critical issue,
   dependency, collision, brief, branch, release, and completion paths.
4. **Coordinator shadow mode**: create installation identity and durable state;
   mirror legacy allocations and compare without changing external output.
5. **Dual-write metadata**: retain existing human surfaces while attaching
   canonical mappings and idempotent operation evidence.
6. **Namespaced emission**: enable new IDs per installation behind an explicit
   feature gate after mixed-version and rollback verification.
7. **Repository publication**: route projections through the serialized
   publisher; remove canonical-checkout writers.
8. **Enforcement**: reject ambiguous new records. Preserve legacy reads and
   mappings indefinitely.

Mixed-version runners must not address one task once by canonical identity and
again by a legacy token. Until all critical consumers support namespaced IDs,
new emission remains disabled.

No migration rewrites existing task IDs, issue titles, historical comments,
commit messages, branch names, or filenames merely for consistency. Backfill
creates mappings and markers without changing identity.

## Rollback

Rollback changes feature preference; it never deletes identity data.

- Each migration phase has an independent gate and documented prior state.
- Before namespaced emission, every phase can be disabled independently. After
  the first namespaced ID is emitted, the dual-read codec, migrated identity
  resolution, operation schema, fencing checks, and reconciliation engine form
  a permanent compatibility floor and cannot be disabled.
- Readers continue resolving every canonical ID observed before rollback.
- Origins, allocated IDs, mappings, redirects, operations, fencing revisions,
  and audit evidence are retained.
- Namespaced tasks created before rollback remain valid; they are not renumbered
  into legacy IDs.
- Pending operations are replayable through their original operation IDs.
- Rollback disables newer emission or projection paths only. The runtime keeps
  the newer codec, operation schema, fencing checks, and reconciliation engine
  available until every namespaced and pending operation reaches a durable
  result.
- Mapping corrections append superseding records rather than rewriting history.
- Canonical/legacy disagreement preserves both forms, emits a reconciliation
  report, and blocks close, merge, reassignment, completion, or destructive
  enrichment until resolved.
- Restoring legacy dispatch does not reactivate stale claims or weaken newer
  fencing tokens.

If a rollback cannot retain read compatibility, it is not a safe rollback and
must stop before disabling the newer writer.

## Security and privacy

- Identity is not authorization. Possession of a task or origin ID grants no
  repository, claim, dispatch, merge, or approval permission.
- Origin IDs and operation IDs are opaque public correlators, not secrets.
- Canonical markers from issue bodies, comments, branches, or external actors
  are untrusted until validated against repository context and actor authority.
- External content cannot bind or redirect an origin, repository, issue, or
  task mapping.
- Mapping and origin lifecycle changes require authenticated maintainer
  authority and append-only audit evidence.
- Public records contain no local path, hostname, username, email address,
  device name, private repository slug, private basename, or credential.
- Payload hashes prevent an idempotency key from being reused with altered
  intent but must not include secrets in public logs.
- Signed approval remains separate from identity; identity never implies
  consent.

## Required invariants

1. One namespaced canonical token identifies at most one task globally.
2. One `(home repository identity, legacy token)` identifies at most one legacy
   task.
3. A task's canonical token never changes and is never recycled.
4. One origin and sequence pair identifies at most one top-level task.
5. Restored state cannot allocate until it proves a safe high-water mark and
   exclusive fenced ownership epoch.
6. Legacy tokens remain valid and require verified repository context.
7. Bare legacy tokens are never resolved globally by current working directory.
8. Repository rename or transfer cannot change task identity.
9. Issue numbers are never resolved without verified repository identity.
10. Replaying one operation cannot create an additional effect.
11. Reusing an operation ID with different content always fails.
12. Stale fencing tokens cannot mutate or release newer ownership.
13. Offline allocation requires no forge or repository mutation.
14. Reconciliation never silently discards local or human work.
15. Canonical/legacy disagreement blocks destructive actions.
16. Session provenance labels never determine task identity or authority.
17. Human canonical checkouts are automation-read-only.
18. Missing backup evidence is reported as preservation failure.
19. Rollback preserves all identities already emitted.

## Implementation ownership

The roadmap children implement non-overlapping parts of this contract:

| Issue | Owned contract |
|---|---|
| #27148 | Lexical limits, codec, structured fields, and table-driven fixtures only; no repository resolution |
| #27149 | Critical consumer migration, explicit-context enforcement, mixed-reader compatibility, and parser inventory |
| #27150 | Origin lifecycle registry, allocation, ownership epochs, coordinator operation intake/state, migration gates, backup, restore fencing, and rollback control |
| #27151 | Repository-bound task, forge, issue, legacy-resolution, and alias mappings |
| #27152 | Checkout-free Git publication primitive |
| #27153 | Per-repository publication outbox execution, leases, replay, and durable publication outcomes |
| #27154 | Targeted forge-event ingestion, ordering, and reconciliation |
| #27155 | Canonical read-only enforcement, lock relocation, preservation, and recovery policy |

Every child owns strict input validation, authorization, private-data handling,
audit evidence, and rollback tests for its surface. #27150 owns the coordinator's
operation state machine; #27153 owns execution and evidence for publication
operations drawn from that state.

## Acceptance contract for implementation children

### Codec and resolution

- Table-driven fixtures accept canonical legacy, namespaced, and hierarchical
  forms and reject malformed, uppercase, oversized, zero, signed, path-like,
  whitespace, control-character, and shell-metacharacter forms.
- Parse and format round-trip to one canonical output under Bash 3.2.
- Bare legacy resolution succeeds with exactly one explicit repository context
  and fails for zero, conflicting, or cross-repository contexts.
- Existing TODO lines, briefs, branch names, PR titles, `ref:GH#NNN` mappings,
  and release extraction retain legacy behavior.

### Allocation and recovery

- Concurrent local processes allocate unique, monotonic sequences in one origin.
- Multiple offline origins with identical local counters cannot collide.
- Clock rollback cannot create a duplicate origin or task identity.
- Crash before and after transaction commit recovers without reuse.
- Restore tests reject an origin-only or stale-counter backup and advance beyond
  every verified published high-water mark.
- Reinstall without complete continuity evidence creates a new origin.

### Mapping and replay

- Identical issue numbers in two repositories resolve independently.
- Repository slug rename preserves identity; immutable-object mismatch requires
  an explicit migration.
- Duplicate delivery returns the original operation result; changed payload with
  the same operation ID conflicts.
- Timeout after successful issue creation is reconciled by canonical marker and
  does not create a second issue.
- Concurrent claims have one fenced winner; stale release cannot clear it.
- Duplicate and out-of-order forge events converge or produce an explicit
  conflict without overwriting newer state.

### Migration and rollback

- Before namespaced emission, every phase can be disabled independently. After
  emission, rollback tests enforce the permanent compatibility floor while
  allowing newer emission and projection paths to be disabled.
- Mixed legacy and namespaced runners cannot double-dispatch one mapped task.
- Shadow mode detects differences without external writes.
- Rollback after namespaced emission preserves IDs, mappings, pending operations,
  and fencing state.
- Backfill does not rewrite historical IDs or infer identity from titles alone.

### Canonical isolation and preservation

- Tests snapshot the resolved canonical HEAD commit, index bytes, tracked,
  untracked, and ignored payload hashes, file modes, file types, symlink targets,
  protected canonical refs, and directory inventory; run allocation,
  init/repo-verify, issue sync, pulse, publication, release, update, and cleanup;
  then prove identity. Publication-owned refs are asserted separately against
  their declared lifecycle.
- The same suite passes with clean, dirty, stale, and deliberately unrelated
  human canonical changes.
- Runtime locks and temporary state appear only in Git common or fenced runtime
  storage and survive concurrent success, timeout, crash, and owner death without
  dirtying a checkout.
- Preservation fixtures verify backup manifests and hashes before recovery and
  prove unresolved backups cannot be pruned.

### Security and portability

- Untrusted markers and external contributors cannot bind identity or authority.
- Public serialization contains no local/private identifiers or secrets.
- Malicious task strings cannot alter paths, shell arguments, SQL, regexes, or
  forge requests.
- Implementations pass ShellCheck, Bash 3.2, Markdown, privacy, secret, and full
  framework validation.

## Consequences

Namespaced IDs are longer than legacy IDs, and migration requires explicit
context in code that previously relied on titles, numeric regexes, or process
cwd. That cost buys offline uniqueness, repository isolation, deterministic
replay, safe multi-machine operation, and removal of human canonical checkouts
from the automation write path.

The next implementation step is the dual-read codec in issue #27148. New ID emission remains prohibited until the critical consumers, coordinator recovery,
mixed-version tests, and rollback gates defined here are implemented.

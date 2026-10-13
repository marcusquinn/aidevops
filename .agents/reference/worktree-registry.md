# Worktree registry boundaries

The registry records ownership evidence. A missing row is not proof that a
worktree is unused, and a successful read is not permission to archive or delete.

## Current module responsibilities

| Module | Responsibility |
| --- | --- |
| `scripts/shared-worktree-registry.sh` | Existing shell API, ownership mutations and compatibility adapters |
| `scripts/shared-worktree-registry.py` | Read-only path resolution and ownership snapshots using Python standard library |
| `scripts/shared-worktree-registry-owner.py` | Atomic claim and compare-and-swap transfer transactions |
| `scripts/shared-worktree-registry-platform.py` | Path normalization, conservative PID absence and process-time comparison |
| `scripts/worktree-owner-contract-remove.py` | Existing exact-owner transaction around native Git removal |
| `scripts/worktree-process-policy.sh` and `worktree-process-providers.sh` | Platform selection and process observations, separate from registry queries |
| `scripts/pulse-cleanup-worktree-removal.sh` | Cleanup policy; retains its uncertainty and ownership guards |

Do not add another registry, a service daemon, or a generic persistence layer for
these local reads. Path lookup and snapshot lookup share one reader. Keep the
shell facade and same-stem Python companions together when packaging fixtures;
the shared test-copy helper supports explicit lazy-loaded siblings and families.

## Snapshot contract

`check_worktree_owner_snapshot PATH` preserves its six-field pipe-delimited
output. `check_worktree_owner PATH` preserves the historical five-field output.
Both propagate these exit codes:

- `0`: an ownership row was read successfully.
- `1`: the database or requested ownership row is absent.
- `2`: evidence is unavailable, including inaccessible/corrupt databases,
  incompatible schemas or an unavailable Python reader.

An error must not grant cleanup authority. Existing callers which collapse
nonzero statuses still need individual review before using registry absence to
replace process visibility checks. Legacy schemas are migrated by existing
mutation paths, not by the new snapshot reader.

The reader opens SQLite using an encoded `mode=ro` URI and reads inside one
transaction. Normalized keys use the primary-key index. Legacy alias resolution
scans stored paths only after an indexed miss. This preserves alias compatibility
without imposing a full scan on every current-key lookup.

## Scope and future decomposition

The shell library retains API validation, migration and simple SQLite operations.
Its embedded Python has been extracted into separate reader, owner-transaction
and platform modules, verified with existing claim/transfer/release suites. Keep
transactions, process-generation checks and cleanup policy as explicit boundaries;
do not turn the read module into a catch-all command dispatcher.

The existing removal transaction locks database writers, not just one worktree.
Replacing it requires a complete lifetime protocol spanning launch, descendants,
handoff and cleanup. This read-side change does not implement that protocol,
remove global process checks, or opt old worktrees into automatic cleanup.

## Management authority

Pulse is responsible only for its own worktrees. Users are responsible for their
own worktrees; Pulse must not automatically archive or remove them. This is the
selected management boundary, not an optional degraded-visibility bypass.

Persistent creator/manager provenance and a current process owner are distinct:
releasing a worker's active claim must not erase management provenance, and a
missing claim must not transfer management authority to Pulse. Managed-repository
membership, branch names, task IDs and age are not creator proof. Legacy trees
without explicit provenance remain outside automatic cleanup eligibility.

Creation must record Pulse provenance before launch. Reuse must validate it,
never manufacture it from an existing user worktree. Every automatic archive and
removal entry point must enforce the same scope check before mutation. Provenance
is necessary but not sufficient: active work and uncertain descendant state still
block cleanup of Pulse-owned trees.

This boundary is the implementation target; the current reader/continuation
changes do not yet add persistent creator provenance or enforce it across all
Pulse cleanup paths.

## Lifecycle audit and removal prerequisites

`headless-runtime-worker-prepare.sh` claims ownership before launch.
`_hrw_claim_worker_worktree` in `headless-runtime-worker.sh` handles dispatcher
handoff and generation-checked continuation. Continuation now allows its
absent-owner fallback only for snapshot status `1`; status `2` or empty successful
output reports `worker_worktree_owner_unavailable` without claim or transfer.

The dispatcher also propagates snapshot errors through
`_dlw_capture_reused_worktree_owner`: unavailable evidence stops reuse before
claim or preparation, with `worktree_owner_unavailable`. Its existing atomic
repair of a successfully read but incomplete ownership row is unchanged.

`_hrw_finish_cleanup` releases the registry ownership via an exact-owner contract.
That function does not itself verify descendant quiescence. The sandbox execution
path has process-group cleanup and sampled descendant identities in
`sandbox-exec-helper.sh`; `headless-runtime-invoke.sh` also has a bare execution
path. Therefore registry release alone is not a universal descendant-drained
receipt. This is a limitation of using registry evidence for removal, not proof
that the current process-guarded cleanup deletes active trees.

Before replacing the global process guard, require all of the following:

- Explicit enrollment in a managed lifetime protocol; legacy and unmanaged trees
  remain unknown rather than becoming eligible by age or absent registry row.
- One shared exclusion boundary for launch, transfer and removal, with a
  generation token preventing a stale owner from releasing a replacement.
- Ownership retained until descendants are verified stopped or their ownership
  is explicitly transferred; expiry or a dead wrapper PID alone is insufficient.
- An exclusive cleanup phase preventing new claims between the last check,
  archive creation and native Git removal. Unknown evidence aborts that phase.
- Verification through existing runtime, ownership-transfer and sandbox suites,
  including crash, bare-runtime, surviving-child and concurrent-claim cases.

Do not introduce a second independent lease database. Reuse the registry's
identity contract and keep process containment separate from SQLite queries.
Cooperative locks cannot prove that arbitrary external shells are absent.

## Linux containment feasibility

An isolated local probe on 2026-10-13 verified a working systemd 260.4 user
manager without sudo. A transient service with `Type=exec`, `ExitType=cgroup`,
`KillMode=control-group`, `RuntimeMaxSec` and `systemd-run --user --wait --pipe`
continued tracking a child after its launcher exited. The child completed after
two seconds; the service reported success after 2.048 seconds. A second probe
started a child in a new session: the three-second runtime limit reported timeout
after 3.184 seconds despite the launcher itself exiting successfully. Both
probe units were subsequently collected and reported inactive/not-found.

This supports a native user-cgroup backend rather than another sampled-PID
supervisor. It is feasibility evidence, not an implemented cleanup permission.
In particular, launcher exit status alone must not be interpreted as success.

Integration must bind the unit invocation generation to the Pulse worktree's
persistent provenance, preserve the final unit result and quiescence evidence
before collecting the unit, and retain exclusion through archive/removal. A
missing or collected unit without a matching durable receipt is unknown, not
inactive proof. Environment forwarding, cancellation, worker retries and abnormal
supervisor exit need explicit integration tests. Missing user-systemd support
must retain the existing fail-closed path; these probes establish no macOS or
container-host coverage.

## Verification

Run the existing shell suites `test-worktree-registry-session-claim.sh`,
`test-worktree-registry-dead-owner.sh`, `test-worktree-registry-prune-batch.sh`,
`test-worktree-registry-unset-home.sh`, `test-test-helpers.sh`, and
`test-profile-readme-boundary.sh` under `scripts/tests/`.

Run `test-headless-runtime-helper.sh` for continuation behavior, including
unavailable/empty snapshots, genuine absence, and a concurrent replacement owner.
Run `test-precreation-failure-skip.sh` for dispatcher read failures and the
prelaunch ownership boundary.

The reader uses no procfs, platform-specific subprocesses or external packages.
Local Linux tests are not evidence of execution on macOS or Windows. Keep the
Python 3.9 annotation gate and shell portability checks enabled.

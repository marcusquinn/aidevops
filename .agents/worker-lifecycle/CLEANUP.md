# Cleanup and preservation contract

## Status and authority

One policy applies to Pulse, interactive sessions and other supported launchers.
Launchers supply registration facts; they do not select different safety rules.
The new registry and native OS adapter are the only lifecycle evidence sources.
Legacy registries, dispatch ledgers and old owner statuses cannot fill evidence
gaps or authorize an operation. Git and the filesystem supply content evidence,
not process liveness.

`worker_lifecycle/cleanup_policy.py` implements a **report-only decision table**.
Its assertions are inputs for future verified evidence collectors, not CLI flags
or proof objects. It performs no I/O and always reports `cleanup_authorized=False`.
Neither a production evidence collector nor a destructive executor is connected
to this policy. Tests of the decision table are not archive/restore validation.

`directory_handle.py` provides an operation-local, read-only directory check. It
holds an open descriptor and compares device/inode identity at the canonical path.
Observed replacement, loss of access, process change or closure invalidates the
handle. It is not persistent generation identity, a content snapshot, a Git
identity check or an admission lock. Contents can change while the directory still
matches. A positive check cannot eliminate a race with a later pathname operation.
After a crash/restart, evidence must be established anew; saved device/inode values
alone are not sufficient. Retained registry reports qualify these tests on Linux
and macOS Intel for their recorded artifact and environments.

Default observe-only launch bindings use a per-attempt UUID, not a verified physical worktree
generation. Observation failure deliberately permits the original command to
execute. Consequently these bindings cannot supply `generation_verified`,
`ownership_complete` or `admission_closed` to the cleanup policy. A later active
admission protocol must deny managed launches when admission is closed/unavailable,
without silently changing the existing observe-only launch contract.

## Transactional admission core

`admission.py` supplies an API for cooperating callers, tested in private stores.
It shares the registry's SQLite transaction and journal, not a second database:

- `open_generation` reserves a canonical path for one generation ID. Closed paths
  remain reserved; assigning another UUID cannot bypass closure. Reopening or
  retiring reservations requires a later verified physical-generation protocol.
- `admit` checks open admission and registers the run/binding in one writer
  transaction. Unknown/closed admission, unavailable schema or capacity errors
  reject the request and roll back partial events.
- `close_generation` closes admission and returns all non-ended bindings in the
  same transaction. A racing admission either commits first and is included, or
  observes the closed gate and fails. An empty result does not prove no writers.
- Exact replay of admission returns `False`: acknowledgement of existing state,
  **not permission for a second exec**. Lost acknowledgements need original-run
  recovery. Replaying an old open event cannot reopen closed admission.

Schema 2 supports this API; schema 1 needs the explicit transactional upgrade
described in [REGISTRY.md](REGISTRY.md). No production migration was performed.
The explicit launcher mode and automatically resolved enrolled generations use
this API; unmanaged observe-only launches still bypass it. It is not system-wide exclusion, physical generation
evidence or cleanup authority. Production launcher coverage, descendant quiescence,
restart recovery and closing-versus-exec integration remain to be qualified.
Portable reports cover their recorded source only. The retained Linux and macOS
Intel registry reports include admission and directory-handle checks; they do not
qualify production AI launchers, descendant containment or archive execution.

### Explicit admitted launch

After a controller has reserved a generation in a schema-2 store, invoke the
existing entry point with its **canonical worktree path**, independently of cwd:

```bash
python3 -E -s -B /absolute/path/to/worker-launch.py \
  --state-dir /absolute/private/state \
  --worktree /absolute/canonical/worktree \
  --generation-id GENERATION_UUID --run-id ATTEMPT_UUID -- native-command
```

Both IDs are required together. The attempt ID must remain stable across delivery
retries. This mode disallows `--initialize`, verifies the declared reserved path,
holds a directory handle until exec, and records the exact pre-exec process identity.
Process cwd is neither ownership evidence nor an admission condition. Native
runtime working-directory options remain separate from lifecycle registration.
Closed/unknown admission, missing state, schema 1, replay, capacity failure or
unavailable observations return 75 without executing the native command. Invalid
CLI combinations return 2. Successful exec preserves native output and exit code;
native exec failures retain the existing 126/127 convention. Reconciliation records
the process ending, including a launch that failed after committing admission.

The directory descriptor is non-inheritable and closes on exec; it is NOT a writer
lock for the worker's lifetime. An already-admitted run may reach exec after close:
it remains a registered non-ended owner, so close is not permission to remove its
worktree. Descendants may outlive that process; separate containment is still needed.
No installed launcher hook is switched into this mode by these changes.

### Bare and sandbox integration

Both source launch paths use `worker_lifecycle_prepare_launch` in the existing
`scripts/worker-lifecycle-state.sh`. A controller supplies the **new registry's**
`AIDEVOPS_LIFECYCLE_GENERATION_ID` and `AIDEVOPS_LIFECYCLE_RUN_ID` after reserving
admission. These are per-launch metadata, not a global feature toggle or legacy
dispatch IDs. Their presence selects mandatory admission; partial context denies
execution. Disabling observation cannot bypass a mandatory admission request.
Private workloads with this public-store context are refused rather than logged
into that store. Existing private/disabled observation without admission metadata
retains its previous behavior.

The shim remains inside sandbox environment clearing and egress/seatbelt policy;
it does not expand native-command permissions or disable isolation. Bare launch
still requires the existing sandbox policy to permit it. The bare integration's
fixture stubs only that upstream policy and runtime setup, then executes the real
launch-boundary function; the sandbox fixture exercises the command-line helper.
Tests use disposable state and `touch`, not AI workers. These shell integrations
have Linux evidence; the portable Mac report does not cover the shell hooks.

Without explicit controller metadata, the shim checks the new admission table.
A registered generation must pass enrollment validation and admission; a closed
or damaged enrollment cannot fall back to hypothetical registration. Unregistered
paths and schema-1 stores still use observe-only registration. Bootstrap failures,
observation opt-out and private-workload exclusions remain coverage gaps: this
staged integration is not yet universal mandatory admission.
Do not infer complete coverage from the two tested launch boundaries.

### Restartable generation enrollment

`worktree_create_registered` invokes `worker-registry.py enroll --initialize --allow-schema-1-observation`
after creation and retains the tree if enrollment fails. Private/disabled
observation is excluded. An absent store can be initialized; schema 1 is never
implicitly migrated. With this compatibility flag, an un-enrolled schema-1 tree
continues observe-only with a `coverage-gap: schema-upgrade-required` diagnostic;
it has no admitted generation. Existing markers or admission tables in schema 1
are contradictions and cause refusal. Ordinary `enroll` remains schema-2-only.
Coordinate migration before requiring admission for these installations.

`enroll --path PATH` publishes a private `aidevops-generation.json` in the Git
administrative directory, not among worktree files. It contains a UUID and the
installation, canonical paths and directory inodes (marker format 2). Publication does not
overwrite another creator's marker. Repeating after an interruption between marker
publication and the SQLite transaction finishes registration with the same UUID.
`resolve-generation --path PATH` performs validation without creating metadata.
Closed admission, damaged markers and detected directory replacement are refused.
Format-1 compatibility and operation-local device checks are described in
[REGISTRY.md](REGISTRY.md). Device-renumbering tests simulate the identity comparison;
they do not establish native reboot/remount coverage on macOS.

The fingerprint is not an everlasting physical identity: copied metadata and
inode reuse outside the cooperating creation protocol are not excluded. It also
does not register the creator's writer lifetime. Unknown pre-enrollment writers,
interactive sessions and descendants still prevent complete ownership proof.
Linux disposable-Git tests cover creation, enrollment and native launch together;
retained portable reports do not qualify this Git-dependent enrollment path.

### Remaining rollout boundaries

The following source integration points are verified, not an exhaustive inventory
of every possible writer. Paths are relative to `scripts/`.

| Boundary | Existing entry points | Required new-registry contract |
|----------|-----------------------|--------------------------------|
| Native creation | `shared-worktree-create.sh:worktree_create_registered` | Enroll the newly created physical generation; preserve the tree on failed enrollment |
| Existing-tree adoption | `worktree-helper-add.sh`, `dispatch-single-issue-helper.sh`, `pulse-dispatch-worker-launch.sh` | Verify the generation independently; never translate legacy ownership into proof |
| Runtime launch | `headless-runtime-invoke.sh`, `sandbox-exec-helper.sh` | Supply generation and attempt IDs from the new controller, with per-attempt retry semantics |
| Other creators | Release/recovery, scratch, workflow-sync and archive restore callers of `worktree_create_registered` | Cover their actual writer lifetime, not merely the short-lived creation subprocess |
| Removal consumers | `pulse-cleanup-worktree-removal-lifecycle.sh`, `worktree-helper-cmds.sh`, `pulse-temp-worktree-cleanup.sh` | Replace legacy ownership authority only after coverage and generation checks are proven |

Implement enrollment and identity propagation before switching cleanup consumers.
`open_generation` currently reserves an existing canonical directory; it is not a
pre-creation lock or a persistent physical identity check. Do not call it on every
launch with a fresh UUID, infer a generation from path equality, or automatically
reopen a closed path. Recovery of interrupted creation and intentional path reuse
need explicit contracts before that boundary can be considered covered.

## Simple algorithm

1. Verify the physical worktree generation, close new admission, and establish
   complete ownership coverage. Missing registration or a reused path means hold.
2. Require every admitted run to be ended and establish that no writers remain.
   A dead parent is not proof that its children or a shared runtime stopped writing.
3. Inventory all results. Incomplete inventory means hold, not an empty worktree.
4. If results need preservation, propose an archive. If preservation is already
   verified, propose removal. Unknown preservation means hold.
5. A future executor must revalidate evidence and perform the protected operation;
   a report is never a deletion capability.

| Evidence | Report |
|----------|--------|
| Unknown generation, uncovered owner, open admission | Hold |
| Any alive/unknown run, no recorded runs, possible remaining writers | Hold |
| Failed or incomplete content inventory | Hold |
| All safety preconditions proved; unique local results | Archive candidate |
| All safety preconditions proved; results demonstrably preserved | Remove candidate |

`ended` records process termination, not task success. No push and no PR is a
normal preservation case: local work may be the only copy. A PR or push is also
not sufficient evidence that the latest work is preserved. Squash merges mean
that commit ancestry alone cannot prove work was lost or remains unpublished.

## Archive payload qualification

`tests/test_preservation.py` exercises only the existing archive payload engine
(`scripts/worktree-archive-helper.sh`), not its legacy lifecycle controllers.
Fixtures use private temporary Git repositories and an invalid legacy-state
sentinel. Restore uses `--verification-copy`, avoiding registered restoration.
No production registry, archive or worktree is touched, and no cleanup eligibility
is derived from the engine. These Git/Bash tests are not included in the portable
standard-library registry validator.

Linux checks cover unpublished commits, independent staged/unstaged changes,
binary edits, new files with unusual names, symlinks, corrupt payload rejection
and late source changes. The original worktree path is made unavailable during
round-trip validation, while its contents and common Git repository remain intact.

**The existing engine is not yet sufficient for automatic preservation:** a
dedicated test demonstrates that ignored local configuration is omitted. Such a
passing limitation test is a blocker, not proof of full preservation. The compact
archive also depends on retained base Git objects; it is not evidence of recovery
after loss of the common repository. Before integration, preserve necessary ignored
data (excluding only explicitly reconstructible caches), and either pin/verify
base retention or build a self-contained archive. Until then, this backend must
not justify a `preservation="verified"` decision for arbitrary worktrees.

## Preservation and executor requirements (not yet implemented here)

An archive must preserve local commits and required Git objects, index/staging
state, unstaged modifications, deletions, relevant untracked and ignored files,
symlinks and executable modes. Submodules, external dependencies and unsupported
filesystem features must be handled explicitly or block the operation.

Do not blanket-exclude ignored files: they may contain local databases, secrets
or configuration. Reproducible dependency trees and caches may be excluded only
under an explicit reconstruction policy. Archives containing secrets stay local
and private; no automatic public push, PR or upload is part of cleanup.

The future executor must:

- Bind a durable operation ID to a verified physical generation and inventory.
- Close admission atomically with respect to every supported launcher, retaining
  that exclusion through final removal. A boolean or expiring lease does not fence
  uncooperative writers; full coverage and an enforceable no-writers contract are
  prerequisites. Unregistered/ad-hoc access remains outside that guarantee.
- Write the archive to a private temporary destination; check space and errors.
  Publish a durable receipt only after integrity and isolated restoration checks.
- Revalidate generation and content before removal. Content changes, path reuse,
  lost exclusion or incomplete evidence invalidate the plan.
- Keep the original on archive, verification, I/O or disk-full failure. Never
  delete the original to make room for its own unverified archive.
- Resume idempotently after crashes: an interrupted archive is not a verified
  receipt; a verified archive with an existing source must be revalidated before
  removal; partial removal must be reconciled without touching a replacement
  generation. An archive must not depend on objects deleted with the source.
- Record retirement only after verified removal. Archive retention and later
  archive deletion are separate policies, not implicit consequences of `ended`.

Slow filesystem/Git operations must not hold SQLite write transactions. Safety
across those operations requires persistent exclusion and revalidation, not one
long transaction. This is a local-host system, not a distributed SQLite service.

## Coverage matrix

| Scenario | Evidence or remaining work |
|----------|----------------------------|
| Identity across exec; natural exit; zombie | Native process validator on qualified hosts |
| Hidden PID / permission ambiguity | Injected tests; real denial remains unqualified |
| Reboot, real PID reuse, generation-token collision | Not exercised by the current native validation |
| Duplicate events, conflicts, stale observations, concurrent writers | Existing registry contract tests |
| Crash before/after SQLite commit | Owned subprocess tests; not machine power-loss testing |
| One run with many worktrees; multiple runs sharing a process | Existing registry contract tests |
| Missing registration, mixed alive/ended owners, missing safety proofs | Simulated decision-table tests |
| Ended worker with unpublished local work | Simulated preservation decision; no destructive operation |
| Archive disk-full, corruption, interrupted restore/removal | Executor integration tests still required |
| Directory replacement, disappearance and symlink substitution | Native disposable-directory tests; operation-local only |
| Admission racing close; duplicate admission; closed-path UUID bypass | SQLite concurrency/transaction tests in isolated stores |
| Explicit launcher denial, native output/exit, retry, missing state, mismatched generation path, cwd independence | Real short-lived subprocess tests in disposable state |
| Real launcher admission racing removal; durable generation after restart | Launcher/generation integration tests still required |

## Integration and replacement

Ordinary OpenCode worker launch hooks register automatically, and Pulse invokes
bounded reconciliation. That does not establish coverage for every interactive
session, retry path, private workload or alternate runtime. Maintain an explicit
coverage matrix before enabling destructive behavior. Multiple logical sessions
in one process need distinct run IDs; shared process liveness cannot prove each
logical session is active.

Unregistered existing worktrees stay unresolved. A future adoption procedure must
establish fresh generation and exclusive admission evidence; it must not import
legacy claims as truth or infer death from age or missing records.

Rollout order: report-only policy, verified registration/generation coverage,
admission and writer exclusion, archive/restore qualification, guarded executor,
then removal of superseded lifecycle readers/writers/schedules. Existing archive
mechanics may be reused only after auditing them for hidden legacy dependencies.
Do not claim the legacy mechanism has been retired while it remains scheduled.

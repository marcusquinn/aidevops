# Cleanup and preservation contract

## Status and authority

One policy applies to Pulse, interactive sessions and other supported launchers.
Launchers supply registration facts; they do not select different safety rules.
The new registry and native OS adapter are the only lifecycle evidence sources.
Legacy registries, dispatch ledgers and old owner statuses cannot fill evidence
gaps or authorize an operation. Git and the filesystem supply content evidence,
not process liveness.

The managed launch contract in [DESIGN.md](DESIGN.md#managed-launch-contract)
defines ownership coverage. Independent worktree writers must register separate
runs before writing, including jobs intended to outlive their launcher. Ordinary
child commands remain the launching runtime's responsibility. Lifecycle does not
discover or control process trees; an unregistered independent writer is outside
the contract, not an owner inferred from PID, PPID or cwd.

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
  remain reserved; assigning another UUID cannot bypass closure. Verified
  retirement releases the reservation atomically with its completion event;
  it never reopens the old generation. Historical generation/run records remain.
- `admit` checks open admission and registers the run/binding in one writer
  transaction. Unknown/closed admission, unavailable schema or capacity errors
  reject the request and roll back partial events.
- `close_generation` closes admission and returns all non-ended bindings in the
  same transaction. A racing admission either commits first and is included, or
  observes the closed gate and fails. An empty result does not prove no writers.
  Cleanup supplies `expected_ended_runs`: closure then requires the exact nonempty
  observed run set to remain ended inside that same writer transaction. A new
  owner or unfinished run rejects closure without writing a close event.
- Exact replay of admission returns `False`: acknowledgement of existing state,
  **not permission for a second exec**. Lost acknowledgements need original-run
  recovery. Replaying an old open event cannot reopen closed admission.

Schema 2 supports this API; schema 1 needs the explicit transactional upgrade
described in [REGISTRY.md](REGISTRY.md). No production migration was performed.
The explicit launcher mode and automatically resolved enrolled generations use
this API; unmanaged observe-only launches still bypass it. It is not system-wide exclusion, physical generation
evidence or cleanup authority. Production launcher coverage, registered-run completion,
restart recovery and closing-versus-exec integration remain to be qualified.
Portable reports cover their recorded source only. The retained Linux and macOS
Intel registry reports include admission, directory-handle checks and disposable
archive/retirement execution. They do not qualify production AI launchers,
unregistered writers or production rollout.

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
worktree. Independently continuing jobs must have their own admitted runs;
ordinary child-command cleanup remains the runtime's responsibility.
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
paths and valid, unmarked schema-1 stores still use observe-only registration.
Bootstrap or registry lookup failures deny launch. Private/disabled workloads
remain unobserved, but their guard refuses enrolled or marked worktrees instead
of bypassing admission. Switching registries cannot bypass an existing marker.
OpenCode and Claude launch boundaries require an explicit work directory; they
do not infer ownership from inherited cwd. Standalone commands outside these
managed entry points remain outside the registered-writer contract. The tested
boundaries do not establish coverage of interactive writers or ad-hoc commands.

### Interactive tool admission

The source OpenCode pre-tool hook registers the runtime PID and runtime session
ID before direct file mutations, Bash calls and bounded-operation starts. File
tools supply explicit targets; command tools supply their working directory and
explicit Git repository options, including repeated `git -C`. The existing shared
command parser and Git identity probes resolve these options; no second shell
parser or process-cwd census is introduced. Directory-changing shell builtins
remain prohibited by the shared command policy. The helper uses the same physical
generation and admission registry as managed launches, without legacy ownership.

The Claude guard uses the native parent of its short-lived hook process and the
runtime-provided session ID. Framework-managed hook commands use `exec` so an
intermediate shell is not mistaken for the owning runtime. Custom command
wrappers are not qualified by this integration.

Replaying the same session/process registration is idempotent, including after
admission closes; it does not start another independent run. A new owner cannot
enter a closed generation. Shared runtime processes are retained conservatively
until native process termination: session completion/release is not implemented.

The existing bounded-operation supervisor also registers its own native identity
before spawning the command. Its lifetime remains governed by the existing
operation drain; lifecycle adds no process-tree supervision. Admission failure
returns 75 without starting the command. Restoration supervisors must also pass
admission. Linux fixtures verify independent registration, ended-supervisor/live-UI
reconciliation, and refusal to start another operation after admission closes.

These hooks do not establish complete writer coverage. Opaque programs must obey
the declared-worktree contract; their internal file accesses are not inferred.
Disposable Linux hook tests are not evidence of live Claude/OpenCode SDK deployment
or macOS qualification. Pre-existing unregistered writers remain uncovered.
Scheduled Pulse cleanup can retire registered generations that satisfy the registry checks.

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
does not by itself register the creator's writer lifetime.

OpenCode's shell environment, bounded-operation supervisor and native launcher
declare their own `AIDEVOPS_LIFECYCLE_RUNTIME_PID` and
`AIDEVOPS_LIFECYCLE_SESSION_ID`. For a new path, the shared helper invokes
`create-worktree`: it exclusively creates the directory, runs native Git,
captures the owner's start identity and binds it before returning the new tree.
Only successful controlled creation records a `created-worktree` event. Ordinary
enrollment or admission of an existing tree cannot mint that evidence.
`prepare-cleanup` exposes the validated receipt as `creation_verified`; this
does not itself authorize deletion. This is not a PID-only liveness test or a
legacy ownership lookup.
Independent launches replace inherited creator identity; excluded launches clear
it. Partial declarations fail without removing the tree. Missing declarations
only enroll the generation and do not establish writer coverage. Callers with
pre-reserved directories retain their existing creation path but do not acquire
controlled-creation provenance. Failed construction retains partial results;
repeating it cannot adopt an existing directory, even an empty one.

Managed producers use `worker-lifecycle-state.sh` to enter the native launcher before execution.
Parent runtime/session identity is replaced; explicit generation/attempt requirements remain mandatory.
Post-completion callbacks run outside that identity. Legacy service receipts cannot replace
registry creation, admission or retirement checks.

Claude creator integration is outside this rollout; standalone creators and unknown pre-enrollment
writers still prevent a claim of complete registered-owner coverage.
Linux disposable-Git tests cover creation, enrollment and native launch; portable reports do not qualify enrollment.

### Remaining rollout boundaries

These verified integration points (paths relative to `scripts/`) are not an exhaustive writer inventory.

| Boundary | Existing entry points | Required new-registry contract |
|----------|-----------------------|--------------------------------|
| Native creation | `shared-worktree-create.sh:worktree_create_registered` | Enroll and bind the runtime-declared creator when available; preserve the tree on failed enrollment/admission |
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

1. Verify the physical worktree generation and establish
   complete ownership coverage. Missing registration or a reused path means hold.
2. Require every admitted run to be ended under the managed launch contract.
   Independently registered jobs remain owners after their launcher exits. A shared
   runtime also needs explicit session-completion semantics, not just PID polling.
   Close admission only if that exact nonempty run set is still ended in the
   admission transaction. A racing new owner means retry, not closure over live work.
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

## Preparation and WIP preservation commands

The registry CLI provides two non-destructive operations:

- `prepare-cleanup --path PATH` validates the physical generation and reconciles
  its registered runs. Empty registrations and
  observation-only bindings report `coverage-gap`; active or unknown runs report
  `waiting-for-runs`. These outcomes leave open admission open, so preparation
  cannot strand a newly created worktree before its first launch. Once all runs
  are ended, closure rechecks their exact set in the admission transaction;
  a racing new owner reports `retry-required` without closing admission.
  Successful closure is permanent. `registered-runs-ended` describes registered runs,
  not coverage of unregistered writers or permission to remove anything.
- `preserve-wip --path PATH --repo OWNER/REPO --base-branch BRANCH --output-root DIR`
  performs preparation, creates a WIP archive, restores an isolated verification
  copy and compares its fingerprint with the source. `DIR` must already exist,
  be canonical, private and outside the source worktree and its administration
  directory. Missing evidence or failed verification leaves the source intact.

Both commands require the usual `--state-dir` before the subcommand. Neither
command initializes/migrates state, reopens admission, removes a worktree or
consults legacy ownership. A failure after closure deliberately leaves the gate
closed. Do not use these commands to inspect a worktree intended for more launches.

Successful preservation records a receipt in the new registry. Repeating the
same generation/content/destination request rechecks its existing archive rather
than treating the old receipt as current proof. The receipt and result retain
`cleanup_authorized=false` and `common_repository_required=true`.

Each archive pins its base commit under `refs/aidevops/wip-base/OPERATION_ID`.
This keeps prerequisites reachable through branch deletion and ordinary Git GC;
it does not protect against loss of the common repository. These pins must remain
while dependent archives are retained. Automatic archive/pin retirement is not
implemented by these commands. Git/filesystem work runs outside SQLite write
transactions; only the verified receipt is published transactionally.

## Explicit guarded retirement

`worker-registry.py retire-worktree` executes the registered-writer contract for
a **specified generation**, not whichever resource currently occupies a pathname:

```bash
python3 -E -s -B /absolute/path/to/worker-registry.py --state-dir /absolute/private/state retire-worktree --path /absolute/canonical/worktree --generation-id GENERATION_UUID --repo OWNER/REPO --base-branch main --output-root /absolute/private/archives
```

This command is destructive and is not scheduled automatically. It requires a
controlled-creation receipt, ended admitted owners, closed admission and verified
Git-only preservation. Existing enrollment without creation provenance is not
sufficient. No legacy ownership data is consulted and no branches are deleted.

The executor journals its intent in the same SQLite registry, then uses native
`git worktree move` to claim the tree inside a private sibling directory. Git
metadata and the saved content snapshot must match before native removal of that
private path. The original public name is never a removal target. A per-generation
OS lock serializes controllers; filesystem work does not hold a SQLite writer
transaction. The archive and its pinned base remain after removal.

Explicitly launched helpers inherit the lock descriptor. If the controller dies
while its helper is still running, another controller cannot acquire the lock
until that helper closes its descriptor. This uses kernel descriptor lifetime,
not descendant discovery, PID signalling or cwd inspection.

Repeat the same command and generation ID after interruption. Completed relocation
can resume even if another directory now occupies the public name. Completed
removal can be acknowledged after a lost acknowledgement. Completion releases the
path reservation, permitting a new controlled generation at that name; a retry
for the old UUID never targets the new generation.

An incomplete Git metadata update, changed archive, changed private tree, partial
removal or uncertain outcome stops rather than guessing. The journal,
archive and surviving private data remain available for recovery. The executor
does not run repository-wide `git worktree repair` or prune unrelated metadata.
Git locks remain effective: relocation is not forced and removal uses only the
single force needed for archived dirty state. Ignored files are deliberately
discarded with the worktree, never added to the archive.

`tests/test_retirement.py` uses real Git and the CLI in disposable repositories,
including interruption boundaries and public-name reuse. The portable registry
validator includes these checks. Only reports listing them qualify that artifact's
fixture behavior; they do not qualify production scheduling or existing worktrees.

## Archive payload qualification

`tests/test_preservation.py` exercises the existing archive payload engine
(`scripts/worktree-archive-helper.sh`) and its new registry orchestration,
not its legacy lifecycle controllers.
Fixtures use private temporary Git repositories and an invalid legacy-state
sentinel. Restore uses `--verification-copy`, avoiding registered restoration.
No production registry, archive or worktree is touched, and no cleanup eligibility
is derived from the engine. The portable registry validator includes these
Git/Bash tests and their actual source dependencies.

Linux checks cover unpublished commits, independent staged/unstaged changes,
binary edits, new files with unusual names, symlinks, corrupt payload rejection
and late source changes. The original worktree path is made unavailable during
round-trip validation, while its contents and common Git repository remain intact.

Untracked symlinks use the PAX payload's actual mode and link target, not an
allowlist derived from umask. Restoration sets the mode without following the
link and verifies it; unsupported restoration fails rather than changing the
target or silently normalizing permissions. Source permissions are never changed.
The `untracked_symlink_modes` fingerprint field binds modes into verification.
Fingerprints without that field verify legacy payload content only, not permission
preservation, and cannot substitute for current preservation evidence.
The portable test crosses creation and restoration masks `022`, `077` and `002`,
including dangling links and ordinary untracked files.

Ignored files are deliberately excluded from WIP archives. The corresponding test
verifies this policy, not a preservation defect or a requirement to expand capture.
A WIP archive is not a full backup of the local working environment.

The compact archive depends on retained base Git objects; the round-trip test is
not evidence of recovery after loss of the common repository. Preservation evidence
must describe the WIP payload and its actual Git-object dependencies, not claim a
self-contained backup or preservation of excluded data.

## Preservation policy and executor invariants

An archive must preserve local commits and required Git objects, index/staging
state, unstaged modifications, deletions, non-ignored untracked files,
symlinks and executable modes. Submodules, external dependencies and unsupported
filesystem features must be handled explicitly or block the operation.

Honor the existing Git ignore policy. Do not add ignored files, even when they
contain local configuration or databases: sensitive data must not unexpectedly
enter a WIP archive. Do not introduce filename exceptions or content-based guesses
to override that policy. Exclusion alone is not a secret scanner; archives remain
local and private, with no automatic public push, PR or upload.

The executor must:

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

## Registry-driven cleanup pass

`worker-registry.py cleanup` selects registered generations from the lifecycle
database, not filesystem age, PR status or legacy ownership records. Required
arguments are `--repos-config` and `--output-root`; `--budget-seconds` and `--limit`
bound the pass. The time budget stops admission of further candidates, not an
already-running filesystem operation; the caller retains its hard watchdog.

Repository configuration defines scope only. Entries with `maintenance: false`
or `local_only: true` are excluded. Missing or detached canonical checkouts do not
establish scope. The archive receives the canonical checkout's actual branch name,
not a guessed default or a commit ID passed as a branch name.

Only controlled-creation receipts permit calling the generation-bound retirement
executor. Enrollment alone remains a coverage gap. Live or uncertain owners hold
the source. Retries use the recorded retirement plan, including its archive root,
and do not redirect an interrupted operation to a replacement at the public path.
A private cursor rotates candidates across bounded passes; it is not deletion
authority. A pass lock prevents overlapping collectors.

Pulse's `cleanup_worktrees` entrypoint calls this operation without initializing or
migrating the registry. Missing state/configuration or a failed invocation does not
fall back to the old cleanup passes. Disposable tests exercise both refusal and
successful preservation/removal through the actual shell entrypoint.

`cleanup-worktree --path PATH --repos-config CONFIG --output-root ROOT` selects
only that path's currently validated generation and shares the collector's policy
and executor. It never adopts an unknown tree or scans unrelated candidates.
If a source has already moved, use the explicit `retire-worktree --generation-id`
retry contract instead of guessing an operation from a missing public path.

The shared native-removal compatibility entrypoint, manual `worktree-helper.sh
remove`, and the central/temp Pulse removal primitives use this targeted command.
Legacy proof, archive and force arguments cannot authorize deletion or bypass a
missing registry. Manual removal retains branches and external resources; their
cleanup is a separate operation, not an unverified path-based post-removal step.

Legacy candidate selectors still exist and can conservatively hold work before
reaching the registry gate. This is not their complete removal, an exhaustive
inventory of arbitrary Git invocations, or production rollout qualification.

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
| Ended worker with unpublished local work | Archive/restore tests and disposable retirement CLI tests |
| Archive corruption, interrupted relocation/removal, public-name reuse | Disposable retirement integration tests; no production or power-loss qualification |
| Archive disk-full and interrupted restore | Fault qualification still required |
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

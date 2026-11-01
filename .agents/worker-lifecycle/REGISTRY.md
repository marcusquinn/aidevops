# Explicit lifecycle registry

This registry provides observe-only lifecycle tracking, not a replacement cleanup
controller. It never modifies the legacy registry, claims
worktrees, signals workers or authorizes deletion. `cleanup_authorized` is always
false. Ordinary OpenCode worker launches collect metadata automatically in a local
private database; there is no additional scheduler or change to cleanup authority.

## Commands

Run from `.agents/worker-lifecycle/`. Replace placeholders with explicit values.
State must live in a new directory under an existing canonical, user-controlled
parent on a local filesystem, not NFS or a shared-host volume.

```bash
python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state init --max-events 10000
python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state status
python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state register --event-id EVENT_UUID --run-id RUN_UUID --pid PID
python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state bind --event-id OTHER_EVENT_UUID --run-id RUN_UUID --generation-id GENERATION_UUID --path /absolute/worktree
python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state reconcile --limit 100
python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state enroll --path /absolute/linked-worktree
python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state resolve-generation --path /absolute/linked-worktree
```

Identifiers are canonical UUIDs, allocated once by the caller per logical event,
run and generation. Repeat delivery uses the same event ID and exact payload.
Changing a payload under the same event ID is a conflict. CLI `register` samples
live identity, so retrying that command after process exit cannot reproduce the
original payload. Use `ingest` with a saved envelope for exact retries, including
after the process exited. Durable producer delivery/outbox is not implemented yet;
do not pretend ingestion alone solves lost admission end to end.

## Stable event ingestion

`python3 -B -m worker_lifecycle.registry --state-dir /absolute/new-private-state ingest`
reads one JSON object from stdin (at most 16 KiB UTF-8). The envelope fields are:

- Common: `schema: 1`, `type`, `event_id`, `run_id`.
- `type: register`: additionally `identity`, the unchanged capture result.
- `type: bind`: additionally `generation_id` and an absolute `path`.

Unknown fields, duplicate JSON keys, unsupported schema and producer-supplied
terminal observations are rejected. Registration must precede binding; an
out-of-order binding fails without saving its event, so delivery can retry it
after registration. No new PID observation occurs during replay: the historical
identity is stored as a claimed fact, then reconciliation checks its liveness.
This is a trusted, same-user producer interface, not authentication of arbitrary
JSON. No cleanup authorization can result from it.

Run identity here means a caller-assigned worker/session ID backed by one process.
Bindings are hypothetical and caller-provided. Paths are recorded, not inspected,
and generation IDs are not yet verified against Git/filesystem identity. Multiple
claims on the same generation are reported as conflicts, never forcibly resolved.
An unknown observation does not end a run. Shared-runtime session completion needs
an additional session protocol: process survival alone cannot settle it.

## Persistence and recovery

- Initialization exclusively creates a 0700 directory and 0600 database. Existing
  directories are rejected, not repurposed. Failure may leave an incomplete private
  directory; later operations reject invalid identity/schema instead of resetting it.
- Application ID, schema version and `observe-only` mode metadata gate use of the database.
- WAL, FULL synchronous durability, foreign keys and a bounded busy timeout are
  explicit. On macOS fullfsync is requested. Supported storage must provide real
  local locking and durability semantics; no claim of protection against disk loss.
- Event append and state update share one transaction. An exception rolls both back.
- Observations occur outside writer transactions. A conditional version update
  rejects samples made stale by another state change. Terminal runs cannot revive.
- Each bounded pass checks readiness before processing rows, samples each distinct
  process identity once, and rotates unfinished runs by a scheduling cursor.
- Events have a UTC `recorded_at` timestamp generated at insertion, not a claim
  about when the producer performed the action. Sequence orders events; wall-clock
  changes are never used as evidence of process death.
- New-event admission stops at `max_events` (default 10,000; maximum 100,000).
  Payloads are capped at 16 KiB; binding paths at 4,096 characters. Existing exact
  replays still succeed at capacity. No history is silently evicted, and a refused
  observation cannot partially change a run. Status reports capacity and last event.
  This bounds logical journal growth, not a byte-exact disk quota or filesystem WAL
  behavior under a stalled reader. SQLite disk errors remain explicit failures.
- Failed passes are reported. A full journal prevents new events, but unchanged
  observations can still refresh scheduling metadata. Unmanaged observe-only execution continues;
  mandatory admitted execution is refused when registration cannot commit.
  An evidence-preserving retention policy is needed for indefinite operation.

`LifecycleRegistry` stores state in `registry.sqlite3` in `observe-only` mode.
New stores use schema 2. Observation still accepts schema 1 without upgrading it;
other versions are rejected. The explicit `upgrade_schema()` API transactionally
adds the admission table to schema 1 and updates the version, retaining existing
events, runs and bindings. It never adopts historical bindings as admission proof.
Repeated upgrades are no-ops. No automatic migration or production upgrade command
is installed. Back up real state and coordinate clients before a future upgrade:
older schema-1-only code will reject schema 2. Do not reset or downgrade live state.
Event envelope schema 1 is separate and unchanged. Admission requirements and
current integration limitations are documented in [CLEANUP.md](CLEANUP.md).

Generation marker format 2 records the directory inodes alongside canonical paths,
installation and generation UUIDs. Device numbers may change between mounts and
are checked only by the live directory handles during each operation. Format-1
markers are interpreted in memory without rewriting them: valid nonnegative integer
pairs supply their inode components, while every other identity field and the Git
backlink must still match. Closed admission stays closed. This is cooperative
protocol identity, not proof against copied metadata, volume clones or inode reuse.
Older clients cannot read format 2; coordinate clients before new enrollment.

The store is not a trust boundary against malicious same-user code. Installation
UUIDs must not be cloned onto another host; host binding/migration is not enforced
in this prototype. Never use these caller-supplied identities as deletion proof.

## Verification and next boundary

Existing unittest tooling verifies duplicate/conflicting events, transaction
rollback, natural process observation, stale-version rejection, shared processes,
concurrent duplicate writers, and real owned-process crashes before/after commit.
Tests use disposable stores, never production data. Crash tests are not power-loss
or disk-full simulations. The latest native evidence is linked in
[COMPATIBILITY.md](COMPATIBILITY.md). Each report applies only to its recorded
artifact and environment.

Before treating collection as complete lifecycle evidence: implement durable launch-boundary event delivery,
session completion semantics, physical generation capture, host/context binding,
retention and bounded scheduling. Active authority additionally needs
the no-writers contract, migration and rollback from DESIGN.md. Do not enable
cleanup based on this observe-only lifecycle tracking slice.

## Automatic pre-exec observation

`worker-launch.py --state-dir STATE --worktree WORKTREE -- NATIVE_COMMAND ...`
automatically validates and admits a generation registered by the new enrollment
protocol. Without such enrollment it records a hypothetical binding. Both paths
capture the launcher's own process identity and then use `exec` to
replace itself with the native command. PID and start identity survive exec;
native stdout, exit status and signal handling are not proxied by a supervisor.
This records an attempted launch, not proof that exec or the AI task succeeded.
If the native command spawns a separate runtime rather than execing it, that child
is NOT tracked. No cleanup decision may use the wrapper's completion.

The OpenCode and Claude launch paths enable lifecycle checks by default on
supported Linux/macOS installations, independent of systemd or launchd. Both
require an explicit work directory, matching the public `run --dir` contract;
inherited cwd is not used to infer resource ownership.
The default private state is `~/.aidevops/.agent-workspace/worker-lifecycle`;
when `AIDEVOPS_WORKSPACE_DIR` is set, its `worker-lifecycle` subdirectory is used.
`AIDEVOPS_LIFECYCLE_STATE_DIR` optionally overrides the path, not activation.
For a persistent host-level override, put the desired registry directory on the
first line of `~/.config/aidevops/lifecycle-state-dir` (a regular file owned by the
current user, not a symlink). Both worker launchers and scheduled Pulse services
read this same file at runtime; no plist/systemd environment override or service
restart is needed. The location deliberately uses the user's home, not
`XDG_CONFIG_HOME`, which a scheduled service may not inherit. Precedence is the
explicit `AIDEVOPS_LIFECYCLE_STATE_DIR` environment override, then this host file,
then the workspace/default path above. For matching reconciliation, use the host
file rather than a worker-only environment override. The file contains path data,
never shell code; spaces are preserved and expressions are not evaluated. Use an
absolute path or a literal leading `~/`; relative host-configured paths (including
option-like values such as `-registry`) refuse launch rather than leaving native
execution unwrapped. An empty/unreadable file or inaccessible parent directory
also refuses launch instead of silently selecting a different registry.
Only a confirmed absent setting permits workspace/default resolution.
Remove the file to restore workspace/default resolution, after draining the old
registry as described below.
The launchers and Pulse expand a literal leading `~/` in either setting using
the current user's home directory; no shell expression evaluation is performed.
Agent installation prepares the framework workspace before bundle activation and
exports its canonical path to subsequent setup steps. It does not create the
private registry. An explicit custom state path still requires an existing,
canonical parent. Each machine uses its own local state: do not share or copy
this database between hosts.
With lifecycle observation explicitly disabled, workspace preparation failures
produce a warning without blocking bundle activation.
Both hooks pass `--initialize`: after platform readiness, the first launch creates
the private store. Concurrent initializers briefly wait for the winning initializer's
commit. Existing state is validated, never replaced, migrated or repaired; interrupted
initialization refuses launch and requires explicit investigation.
Direct CLI calls without `--initialize` still require an initialized store.
The bare hook comes after
the existing sandbox-required guard. For sandbox execution, the launcher supplies
a worktree hint via `AIDEVOPS_LIFECYCLE_WORKTREE` to `sandbox-exec-helper.sh`;
it is not added to the child's env
allowlist. Original argv passes normal admission before the exec shim is inserted
inside env clearing, egress containment and optional seatbelt. Protected/private
workloads are excluded from observation. Their native guard permits only an
unregistered worktree; it does not create state or record private runs. An enrolled
or marked worktree cannot bypass admission through private mode or observation
opt-out. Never disable sandbox policy to exercise observation.
No producer queue is enabled or shipped; durable delivery is a later boundary.

The hooks start the native gate with `python3 -E -s -B`.
They resolve the Python executable and check launcher bootstrap with `--help`
before wrapping the command. An unavailable entry or incompatible interpreter
refuses execution with status 75. The same resolved
executable is used after sandbox environment clearing.
Python-specific environment variables and user-site customization cannot alter
observer startup; these flags do not remove variables from the native command's
environment. The installed interpreter and system packages remain trusted.
Interpreter/bootstrap failures before the handler is entered are not fail-open;
the wrapper does not retry a native command whose execution may have begun.

Only after a successful lookup confirms an unregistered, unmarked path may an
observation failure print `observation-gap` and still exec the native command.
Unknown registration, failed bootstrap, or a marker belonging to a different
registry refuses execution. The launcher uses `register_attempt` to commit registration and
its initial binding together. A binding error, capacity failure or crash before
commit leaves neither event nor projection from that attempt. Database lock waits
are bounded (2 seconds per connection), but startup
latency is not zero. Initialization retries have a 2-second deadline checked between
attempts; an in-flight SQLite wait can extend that deadline. No scheduler or persistent
global environment is installed. Set `AIDEVOPS_LIFECYCLE_DISABLED=1` to disable launch
observation and Pulse reconciliation; preserve the store. This is not permission
to run on enrolled worktrees without admission. Observation on unregistered paths
remains best-effort: journal capacity is unchanged, and full stores report gaps
rather than deleting evidence.

### Changing or removing the host setting

Pulse observes one selected registry at a time; changing the path does not migrate
records or keep reconciling the old store. Before any cutover (including removing
the setting to return to defaults):

1. Pause new worker dispatch through the existing scheduler controls, keeping the
   old setting in place. Let existing workers finish normally; do not kill them or
   disable lifecycle observation to force a drain.
2. Reconcile the old registry while it is still selected. Allow normal Pulse ticks
   or invoke the existing CLI from the installed `worker-lifecycle` package:
   `python3 -E -s -B -m worker_lifecycle.registry --state-dir OLD_ABSOLUTE_PATH reconcile --limit 100`.
   Each invocation is bounded, so a large registry may require multiple passes.
3. Inspect the same old registry with
   `python3 -E -s -B -m worker_lifecycle.registry --state-dir OLD_ABSOLUTE_PATH status`.
   Do not switch while any runs remain unfinished (including `alive` or `unknown`);
   investigate unknown identities rather than treating them as ended. Draining
   records never grants cleanup authority.
4. With dispatch still paused and the old registry drained, change/remove the
   host setting. Remove conflicting per-process overrides, confirm the new path
   has its required canonical parent, then resume dispatch. Verify new launches
   and Pulse use the same selected registry. Keep the old store intact as evidence;
   do not copy, merge, delete or repair it as part of this configuration change.

### Periodic reconciliation in Pulse

Normal Pulse invocations call `_pulse_reconcile_worker_lifecycle` from
`pulse-wrapper-cycle-gates.sh` before refill, busy, idle and rate-limit early exits.
This local pass is independent of new dispatch work or GitHub availability. It uses
the same state-path precedence as the launchers and requires an absolute state path.
Dry-run, canary, private-workload and lifecycle-disabled invocations skip it.

Each pass considers at most 100 unfinished runs, using the registry's 5-second
cooperative budget and a portable 10-second outer timeout. Existing cursor/version
checks preserve fair batch rotation and reject stale concurrent observations.
Unchanged `alive` or `unknown` results refresh only the optimistic version and
rotation cursor, without appending journal events or replacing prior evidence.
The cursor is a scheduling ordinal, independent of journal sequence numbers.
First observations, changed results/reasons and terminal transitions remain
journaled. Explicit event ingestion retains its existing replay contract.
No store is created by a tick. Missing state is a no-op; invalid state, unavailable
runtime, capacity exhaustion and timeouts are logged without blocking Pulse or
replacing evidence. Unknown process observations never imply termination.

After a worker exits, its record becomes `ended` on a subsequent successful pass,
not through an immediate exit callback. With Pulse stopped there is no periodic
reconciliation. This adds no daemon or scheduler, never signals workers, and does
not change legacy ownership or `cleanup_authorized=false`.

### Atomic attempt contract

`LifecycleRegistry.register_attempt(run_id, identity, generation_id, path)` uses
the existing database and schema, not an outbox or another service. It appends the
existing `register` and `bind` events in one transaction. Their event UUIDs are
UUIDv5 derived from the run UUID with the fixed names `register` and `bind`.
They are idempotency keys, not authentication or secrecy. Retrying requires the
same run ID and unchanged identity, generation ID and path; changed payloads fail.
Exact replay after commit (including after an ended observation) does not change
the run version or revive a terminal run. Two event slots are required for a new
attempt; insufficient capacity rolls back both writes. Existing CLI `register`,
`bind` and single-envelope ingestion remain separate operations, not atomic pairs.

Resolve the worktree path and capture process identity before acquiring the write
transaction. A committed attempt is process evidence plus a hypothetical binding,
not successful exec, application readiness, job completion or no-writers proof.

| Failure point | Result |
|---------------|--------|
| Before commit, including after both SQL writes | Transaction rolls back; no partial attempt |
| After commit, before acknowledgement | Exact replay retains one event pair and binding |
| After commit, before exec | Attempt remains recorded; native launch is unconfirmed |
| Native exec fails | Existing diagnostic/exit status reports failure; recorded attempt remains |
| Registry unavailable | Observe-only launch continues with a coverage-gap diagnostic |

The wrapper allocates a fresh run ID per invocation. It does not persist a retry
request outside the registry or retry native execution; store-level idempotency
does not guarantee capture when storage is unavailable. An observe-only launch may
continue with a coverage-gap diagnostic. Explicit admitted launches instead refuse
execution when admission cannot be confirmed. Neither mode provides an atomic
transaction spanning SQLite and exec. Universal mandatory admission remains a
separate rollout requiring authorization and acceptance tests.

Before admitted native execution, the launcher consumes
`AIDEVOPS_LIFECYCLE_RUN_ID` and `AIDEVOPS_LIFECYCLE_GENERATION_ID`: neither is
inherited by the command. All other environment variables remain unchanged.
A nested launcher must obtain a fresh admission attempt rather than replay its
parent's IDs. This does not establish descendant containment or writer coverage.

The existing tests include actual owned-process crashes before and after commit,
concurrent replay, conflicting bindings and full-journal launch continuation.
See [COMPATIBILITY.md](COMPATIBILITY.md) for tested artifact fingerprints,
environments and remaining limitations.

For a controlled experiment, initialize a dedicated store and set
`AIDEVOPS_LIFECYCLE_STATE_DIR` to its path for ONE already-approved ordinary worker invocation, then run the
explicit `reconcile` and `status` commands above. Do not invent a new worker task
or bypass its normal admission guards. Check the registration/gap log and compare
the runtime's PID, exit and output with the ordinary launcher evidence. The shell
`worker_pid` is NOT the runtime identity: it names a supervisory subshell.

The registry tests exercise live identity across exec, natural exit,
unavailable/full storage and preserved native exit/output. Native macOS AI-worker
and sandbox launcher checks remain separate and unverified. Passing these tests
does not validate Pulse issue dispatch/claim transfer, every egress backend,
protected workloads, automatic scheduling or long-term reliability.

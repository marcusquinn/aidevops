# Explicit lifecycle registry

This slice is opt-in, observe-only lifecycle tracking, not the production worker launcher or a
replacement cleanup controller. It never modifies the legacy registry, claims
worktrees, signals workers or authorizes deletion. `cleanup_authorized` is always
false. There is no scheduler or hidden default database. A disabled-by-default
pre-exec experiment is available for ordinary OpenCode worker launches.

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
  process identity once, and rotates unfinished runs by last recorded event sequence.
- Events have a UTC `recorded_at` timestamp generated at insertion, not a claim
  about when the producer performed the action. Sequence orders events; wall-clock
  changes are never used as evidence of process death.
- New-event admission stops at `max_events` (default 10,000; maximum 100,000).
  Payloads are capped at 16 KiB; binding paths at 4,096 characters. Existing exact
  replays still succeed at capacity. No history is silently evicted, and a refused
  observation cannot partially change a run. Status reports capacity and last event.
  This bounds logical journal growth, not a byte-exact disk quota or filesystem WAL
  behavior under a stalled reader. SQLite disk errors remain explicit failures.
- Failed passes are reported, not silently retried forever. A full journal pauses
  registry ingestion/reconciliation only, not the old worker system. Scheduling,
  backoff and an evidence-preserving retention policy remain deployment prerequisites.

`LifecycleRegistry` stores state in `registry.sqlite3` with schema 1 and mode
`observe-only`. Other schemas are rejected without mutation; only disposable test
stores existed during this change. Never reset a real older store to upgrade it:
an explicit migration is required if one has been created.

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

Before automatic collection: implement durable launch-boundary event delivery,
session completion semantics, physical generation capture, host/context binding,
retention and bounded scheduling. Active authority additionally needs
the no-writers contract, migration and rollback from DESIGN.md. Do not enable
cleanup based on this observe-only lifecycle tracking slice.

## Minimal pre-exec experiment

`worker-launch.py --state-dir STATE --worktree WORKTREE -- NATIVE_COMMAND ...`
records its own process identity and a hypothetical binding, then uses `exec` to
replace itself with the native command. PID and start identity survive exec;
native stdout, exit status and signal handling are not proxied by a supervisor.
This records an attempted launch, not proof that exec or the AI task succeeded.
If the native command spawns a separate runtime rather than execing it, that child
is NOT tracked. No cleanup decision may use the wrapper's completion.

The worker launch path in `headless-runtime-invoke.sh` enables this only when
`AIDEVOPS_LIFECYCLE_STATE_DIR` explicitly names an initialized private store.
Without the variable the original command is unchanged. The bare hook comes after
the existing sandbox-required guard. For sandbox execution, the launcher supplies
a worktree hint via `AIDEVOPS_LIFECYCLE_WORKTREE` to `sandbox-exec-helper.sh`;
it is not added to the child's env
allowlist. Original argv passes normal admission before the exec shim is inserted
inside env clearing, egress containment and optional seatbelt. Protected/private
workloads are excluded. Never disable sandbox policy to exercise observation.
No producer queue is enabled or shipped; durable delivery is a later boundary.

Both hooks require the worker role and start the observer with `python3 -E -s -B`.
Python-specific environment variables and user-site customization cannot alter
observer startup; these flags do not remove variables from the native command's
environment. The installed interpreter and system packages remain trusted.
Interpreter/bootstrap failures before the handler is entered are not fail-open;
the wrapper does not retry a native command whose execution may have begun.

Handled observation/storage failures print `observation-gap` and still exec the
native command. Registration and binding are separate transactions: a partial attempt
can leave a registered run without a binding and must be reported as incomplete
coverage. Database lock waits are bounded (2 seconds per connection), but startup
latency is not zero. No scheduler or persistent global environment is installed.
Remove the opt-in variable to disable this experiment; preserve the store.

For a controlled experiment, initialize a dedicated store, enable the variable
for ONE already-approved ordinary worker invocation, then run the
explicit `reconcile` and `status` commands above. Do not invent a new worker task
or bypass its normal admission guards. Check the registration/gap log and compare
the runtime's PID, exit and output with the ordinary launcher evidence. The shell
`worker_pid` is NOT the runtime identity: it names a supervisory subshell.

The registry tests exercise live identity across exec, natural exit,
unavailable/full storage and preserved native exit/output. Native macOS AI-worker
and sandbox launcher checks remain separate and unverified. Passing these tests
does not validate Pulse issue dispatch/claim transfer, every egress backend,
protected workloads, automatic scheduling or long-term reliability.

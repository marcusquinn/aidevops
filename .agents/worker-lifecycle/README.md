# Worker Lifecycle

Portable, user-space worker lifecycle tracking, developed as an observe-only replacement for
the legacy lifecycle. See [DESIGN.md](DESIGN.md) for the full architecture.

## Process observation

Python 3.10+; standard library only. No installation, daemon, database or scheduler
is needed for this slice. No command changes worktrees, ownership, legacy state,
or processes. Python bytecode writes can be disabled with `-B` as below.

Run from this directory:

```bash
python3 -B -m worker_lifecycle --installation-id 11111111-1111-4111-8111-111111111111 readiness
python3 -B -m unittest discover -s tests -v
```

The UUID above is an example for manual testing, not a production installation
identity. Explicit registry initialization provisions a stable installation UUID.
Do not reuse or copy an installation identity onto another machine.

`capture PID` returns a versioned identity object. `observe` accepts that identity
object on stdin (not the enclosing capture response). Both check readiness before
processing their target. Exit 0 means a known observation or successful capture;
exit 2 means invalid input, unsupported environment or unknown observation.
An `ended` result does not authorize cleanup or prove descendants have stopped.

Use the same commands on Linux and macOS. Readiness failures
report unavailable access rather than silently skipping tests. Retained results
cover macOS Intel and Linux x86-64 for their recorded source fingerprints.
Apple Silicon is not yet validated. No private macOS selectors are used.
See [COMPATIBILITY.md](COMPATIBILITY.md) for source fingerprints and instructions
for qualifying additional environments.

## Development checks

From the repository root:

```bash
uvx --from ruff==0.11.13 ruff check --no-cache .agents/worker-lifecycle
uvx --from mypy==1.15.0 mypy --config-file .agents/worker-lifecycle/mypy.ini
```

Alternatively install `ruff==0.11.13` in a development virtual environment and run
the same `ruff check`. Ruff is a development-only tool, not a runtime dependency.
Package-local `ruff.toml` scopes enforcement to this package. Existing legacy
Python retains its current checks; expanding scope requires fixing its findings.

mypy checks the production package against Python 3.10, including bodies of
unannotated functions. Incomplete annotations and unused suppressions are errors;
this is a scoped baseline, not a claim of full strict-mode coverage. Both tools
are pinned in CI and remain development-only: neither is included in runtime
installation requirements or validation zipapps. Commands above run from the
repository root. No blanket missing-import or type-error exclusions are used.

Tests use disposable private SQLite stores and short-lived owned children. Native
observation tests reap naturally exited children; storage tests also deliberately
crash their own subprocesses before/after commit. They do not inspect unrelated
processes or mutate existing user data. Access denial is injected, not a claim of
real permission-error, PID-reuse or reboot testing. Generation tokens have finite
precision.

## Lifecycle registry

`worker_lifecycle/storage.py` implements SQLite persistence and transactions through
`LifecycleRegistry`; `tests/test_storage.py` verifies those contracts.
`worker_lifecycle/registry.py` provides the CLI and process reconciliation, not a
second database.

An explicit private SQLite store, event replay, multi-worktree bindings and bounded
reconciliation are implemented; see [REGISTRY.md](REGISTRY.md). `LifecycleRegistry`
uses `registry.sqlite3`, schema 1, in `observe-only` mode. One session may bind
multiple worktrees; multiple sessions in a
shared runtime require separate run/session IDs despite sharing a process identity.
An alive shared process does not by itself establish that every session is active.
No production scheduler or legacy integration is installed by this directory.
See [COMPATIBILITY.md](COMPATIBILITY.md) for the latest reports and their tested
fingerprints. Automatic producer delivery and native
macOS AI-worker/sandbox launcher verification remain outstanding.

For the new native storage/exec checks, copy the standalone
`worker-lifecycle-registry-validate.pyz`; see [REGISTRY-VALIDATION.md](REGISTRY-VALIDATION.md).
It reuses the existing tests in disposable state and produces one JSON report.

## Standalone validators

- `worker-lifecycle-process-validate.pyz`: process identity and observation.
- `worker-lifecycle-registry-validate.pyz`: registry, events and pre-exec contracts.

Both run on Linux and macOS. Retain one report per validator/OS pair: four reports
in total. See [reports/README.md](reports/README.md).

### Build the process validator

From this directory, choose a new output filename:

```bash
python3 -B -m worker_lifecycle.bundle --suite process --output worker-lifecycle-process-validate-new.pyz
python3 -I -B worker-lifecycle-process-validate-new.pyz --check zombie-state
```

Only process-observation modules are included, not the registry, reports or
tests. Archive entry order, timestamps and permissions are fixed; repeated builds
with the same source and compression runtime are byte-identical. The wrapper
propagates validator exit codes. Existing output files are never overwritten.

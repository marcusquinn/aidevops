# Portable registry validation

Copy only `worker-lifecycle-registry-validate.pyz` to the target Linux or macOS
machine. Python 3.10+ with its standard-library SQLite module is required. No
repository checkout, pip installation, OpenCode, account credentials or sudo.

```bash
python3 -I -B worker-lifecycle-registry-validate.pyz --output validation-registry-linux.json
```

On macOS use `validation-registry-macos.json`. Return the report even if the command fails. Existing output files
are never overwritten: choose another filename if it already exists. Test progress
and failure tracebacks go to stderr; stdout and the output file contain JSON.
Exit 0 means every included test passed; 1 means test failure or skipped coverage;
2 means the environment or runner was unavailable. No reboot is needed.

The archive contains the actual implementation and its registry contract tests,
not an independently reimplemented observer. It unpacks into its own temporary
directory, tests there and removes that directory afterwards. The report is kept.
`TMPDIR` can select an existing writable local temporary parent. Do not use NFS or
another shared-host filesystem for native SQLite durability qualification.

## Coverage

- Private SQLite initialization, reopen, WAL/FULL synchronization requirements.
- Duplicate/conflicting events, transaction rollback and concurrent writers.
- Owned subprocess crashes before/after commit (NOT machine power loss).
- Capacity refusal without partial updates, stable event replay after PID exit.
- Identity across exec, natural process exit and reconciliation.
- Unchanged-observation journal suppression, fair batch rotation and stale-version rejection.
- Original command output/exit status when the registry is missing or full.
- Isolated observer startup without removing the native command's Python environment.

Only disposable stores and owned test children are touched. No existing lifecycle
database, worktree contents, scheduler or worker process is modified. No AI task
is launched. Full real-worker/sandbox launcher validation is a separate stage;
passing this archive must not be presented as testing that integration on macOS.

The JSON includes OS/kernel, architecture, Python/SQLite versions, individual test
results, suite `registry-integration`, artifact SHA-256 and explicit untested areas.
A readiness failure stops
before running the suite. Failed tests remain failed rather than being hidden as
unsupported. A result covers only the architecture recorded in that report.

## Build

From `.agents/worker-lifecycle/`, choose a new output filename:

```bash
python3 -B -m worker_lifecycle.bundle --suite registry --output worker-lifecycle-registry-validate-new.pyz
```

`worker-lifecycle-process-validate.pyz` is the process-only validator. The two
archives have different scopes. Latest results are linked from
[COMPATIBILITY.md](COMPATIBILITY.md); compare each report's fingerprint with the
tested artifact. Do not infer validation of a rebuilt bundle from its filename.

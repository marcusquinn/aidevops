## What

`bounded-interactive-operation.mjs` can report `process_signal: null` for an operation that the supervisor timed out or cancelled with SIGTERM. This intermittently fails the plugin test `failure, timeout, and scoped cancellation cannot appear as success` (`.agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs:337`, `assert.notEqual(timedResult.process_signal, null)`).

## Why

- Observed on 2026-10-05 in the `import-check` job (Plugin Import Check, run 37348173944, job 111891983676) for release PR #33657. Failure: `not ok 7 - failure, timeout, and scoped cancellation cannot appear as success`, `Expected "actual" to be strictly unequal to: null`, at `test-bounded-interactive-operation.mjs:337:12`. 1 of 1076 plugin tests failed.
- None of the release commits touched the plugin. The same test passes locally (`node --test --test-name-pattern "cannot appear as success" .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs`). The previous 11 `Plugin Import Check` runs passed. This is a timing race, not a regression.
- Mechanism: `requestTermination` (`.agents/plugins/opencode-aidevops/bounded-interactive-operation.mjs:190-198`) records `operation.processSignal = "SIGTERM"`. `mainClosed` (`:200-211`) then unconditionally overwrites it with `scalar(signal)` from the child `close` event (`:205`). The main child is a supervisor. If SIGTERM arrives before its handler is installed, it dies by signal and `signal` is `"SIGTERM"`. If the handler is installed, it contains the process group and exits with a code, so `signal` is `null` and the recorded termination signal is lost. The test's 30 ms budget makes either ordering possible.
- Impact beyond CI: receipts for genuinely timed-out or cancelled operations can lose the evidence of which signal the supervisor sent.

## How

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/bounded-interactive-operation.mjs:200-211` (`mainClosed`): preserve the termination signal requested by `requestTermination` when the child closes without a signal, e.g. `operation.processSignal = scalar(signal) || operation.processSignal;`. Normal (non-terminated) operations start with `processSignal: ""` (`:138`), so they still report `null` through `bounded-operation-runtime.mjs:101`.

### Implementation Steps

1. Apply the one-line change in `mainClosed`.
2. Run `node --test .agents/plugins/opencode-aidevops/tests/test-bounded-interactive-operation.mjs` several times (e.g. 10 runs) to confirm the test is stable.
3. Check that the plugin's other tests still pass, using the same command CI's `import-check` runs (see `.github/workflows/` Plugin Import Check).

### Hazards

- Do not invent a signal for operations that exited normally. Only a previously requested termination signal may survive.
- Keep `process_exit` unchanged; a supervisor that handled SIGTERM legitimately reports its exit code.

### Files Scope

- `.agents/plugins/opencode-aidevops/bounded-interactive-operation.mjs`

## Acceptance Criteria

- [ ] A timed-out or cancelled operation reports `process_signal: "SIGTERM"` whether the supervisor died by signal or exited after handling it.
- [ ] Successful and failed operations that were never terminated still report `process_signal: null`.
- [ ] `test-bounded-interactive-operation.mjs` passes on 10 consecutive local runs and in CI `import-check`.

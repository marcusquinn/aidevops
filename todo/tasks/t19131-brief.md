## Origin

- **Created:** 2026-11-19, interactive maintainer review of #39170
- **Evidence:** running `bash .agents/scripts/tests/test-browser-qa-helper.sh` on `main` @ `d3300f88c5` gives `Results: 22/23 passed, 1 failed`. The failing case is `runtime-check accepts a valid configured executable` (`configured=0, unset=1, invalid=1, stale=1`). The #39043 PR body said this failure was "tracked separately", but no tracking issue exists (searched `runtime-check configured executable` and `test-browser-qa-helper runtime-check`).

## What

Make the `runtime-check accepts a valid configured executable` case in `.agents/scripts/tests/test-browser-qa-helper.sh` test the current executable-precedence contract, so the suite passes again on `main`.

## Why

The product behaviour is intentional; the test drifted:

- #36329 (commit `c7d08421fa`, GH#36325, 2026-11-01) added `.agents/scripts/playwright-runtime.mjs:140-141`. With `AIDEVOPS_PLAYWRIGHT_BROWSER=chromium`, the per-process bundled-browser selector overrides any configured executable, so `configuredExecutableSetting()` returns `''`.
- The test builds `missing_env` from `runtime_env`, which sets `AIDEVOPS_PLAYWRIGHT_BROWSER="chromium"` (`test-browser-qa-helper.sh:464`). The "configured" case therefore can never see `AIDEVOPS_PLAYWRIGHT_EXECUTABLE`, and `runtime-check` reports `"configuredExecutable":null,"ready":false`.
- No CI workflow runs this test file (`rg test-browser-qa-helper .github/workflows/` is empty), so the failure has gone unnoticed since 2026-11-01. It also hides real regressions in the screenshot guardrail cases in the same file.

Reproduction: with the exact test fixture, `AIDEVOPS_PLAYWRIGHT_BROWSER=chromium` gives `configuredExecutable:null, ready:false, rc=1`. With `AIDEVOPS_PLAYWRIGHT_BROWSER=` (empty) plus an isolated `AIDEVOPS_SETTINGS_FILE`, it gives `configuredExecutable:<path>, ready:true, rc=0`.

## Tier

`tier:simple`: one exact edit in one test file. No product code changes.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/tests/test-browser-qa-helper.sh:486-488`: clear the bundled-browser selector, and isolate persisted settings, for the configured-executable cases only.

### Implementation Steps

1. Replace lines 486-488. `env` applies the later duplicate assignment, so the appended values override `runtime_env`:

```bash
	# GH#36181: with bundled Chromium removed, a valid configured executable
	# satisfies readiness; unset, invalid or stale-pin cases do not.
	# GH#36325: AIDEVOPS_PLAYWRIGHT_BROWSER=chromium deliberately overrides any
	# configured executable, so clear it here; isolate persisted settings so a
	# host browser.playwright_executable cannot leak into the unset case.
	local missing_env=("${runtime_env[@]}" FAKE_PLAYWRIGHT_BROWSER="${tmp_dir}/removed-chromium" AIDEVOPS_PLAYWRIGHT_VERSION="9.9.9" \
		AIDEVOPS_PLAYWRIGHT_BROWSER="" AIDEVOPS_SETTINGS_FILE="${tmp_dir}/no-settings.json")
```

2. Run ShellCheck on the file and run the suite (see Verification).

### Hazards and Compatibility

- **Concurrency/atomicity:** none. This is a test-local env array and `tmp_dir` is a per-run `mktemp -d`.
- **Migration/rollback:** a trivial revert of one test line.
- **Mixed-version/backward compatibility:** product code is unchanged, and the `chromium` override contract from #36329 stays as it is.
- **Idempotency/retry:** the test is deterministic, and `tmp_dir` is removed at the end of the function.
- **Partial failure/recovery:** none.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-browser-qa-helper.sh   # expect: Results: 23/23 passed
shellcheck .agents/scripts/tests/test-browser-qa-helper.sh
```

- **Surface mapping:** the suite run proves both acceptance criteria. ShellCheck proves the edit is lint-clean.
- **Broad verification trigger:** not required, because only a single test file changes.

### Scope Boundaries

**Hard boundaries:** do not change `.agents/scripts/playwright-runtime.mjs`, because its precedence is intentional (GH#36325). Do not add a CI workflow for this test in this task. Wiring it into CI is a separate maintainer decision, since it would be a new CI test gate.

### Files Scope

- `.agents/scripts/tests/test-browser-qa-helper.sh`

## Acceptance Criteria

- [ ] `bash .agents/scripts/tests/test-browser-qa-helper.sh` reports `23/23 passed` on a macOS or Linux host, including `runtime-check accepts a valid configured executable`.
- [ ] Regression guarantee: the unset, invalid-path and stale-pin sub-cases still fail readiness (`unset=1 invalid=1 stale=1` in the case's own diagnostics), and the guardrail cases (`guardrail passes a fitting PNG without sips or magick`, `guardrail fails when a resize is needed and no tool exists`) still pass.

## Context & Decisions

- The precedence in `playwright-runtime.mjs:140-141` was added on purpose by #36329, so the test is what needs to change.
- Out of scope, recorded here for a maintainer decision: this suite is not run by CI, which is why the drift lasted 18 days.

## Relevant Files

- `.agents/scripts/playwright-runtime.mjs:139-152` (`configuredExecutableSetting`) and `:339-354` (`ownedRuntimeStatus`)
- `.agents/scripts/tests/test-browser-qa-helper.sh:439-512`

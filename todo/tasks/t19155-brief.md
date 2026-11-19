## Origin

- **Created:** 2026-11-19, interactive session (maintainer-approved follow-up to #39173 / PR #39175)
- **Decision:** maintainer approved making `test-browser-qa-helper.sh` a CI gate ("1 yes").
- **Evidence:** `test-browser-qa-helper.sh` was red on `main` for 18 days, from #36329 (2026-11-01) until #39175 (2026-11-19). The only CI job that runs it is the advisory `affected-script-tests` job (`.github/workflows/code-quality.yml:29-52`, `continue-on-error: true`). That job only runs on PRs that change a `.sh`/`.py` file the suite names, and it classifies base-branch failures as `pre-existing`. #39043 hit exactly that case: its PR body records `class=pre-existing` and the failure stayed. The suite now passes 23/23 on `main` @ `3080abf23e`.

## What

Run `.agents/scripts/tests/test-browser-qa-helper.sh` as a step in the required `Framework Validation (core)` shard of `.github/workflows/code-quality.yml`, so a regression in the screenshot guardrail, filename safety, stability or Playwright runtime cases fails the required `Framework Validation` context.

## Why

These cases protect user-visible behaviour: screenshot size limits for the vision APIs, Linux use without `sips`/`magick` (#39031), and Playwright browser readiness (#36181, #36325). Because nothing required runs them, contract drift lands silently. The suite takes about 4s and uses only fakes (fake `npx`, fake Playwright module, fake browsers, synthetic PNG headers), so it is cheap enough for a required gate.

## Tier

`tier:simple`: one exact YAML step insertion in one file.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/code-quality.yml:527-528`: add a step after `MCP Helper Help Regression (GH#30473)` in job `framework-validation-core`.

### Implementation Steps

1. Insert this step immediately after the `MCP Helper Help Regression (GH#30473)` step, using the job's 4-space `- name:` indentation:

```yaml
    - name: Browser QA Helper Regression (GH#39173)
      run: bash .agents/scripts/tests/test-browser-qa-helper.sh
```

2. Push the branch and confirm that the `Framework Validation (core)` job log on `ubuntu-latest` shows `Results: 23/23 passed, 0 failed`.

### Complete Write Surface

- **Callers/readers:** the `framework-validation` aggregator (`code-quality.yml:763-791`) already requires the core shard, so no change is needed there.
- **Writers/mutation paths:** N/A. The suite writes only to `mktemp -d` dirs, which it removes.
- **Existing verification/tests:** the suite itself. `.agents/scripts/tests/test-ci-workflow-timeouts.mjs` validates job timeouts, and adding a step does not alter them.
- **Schemas/config, mirrors, migrations, cleanup:** N/A. This is a workflow-only change, `.github/` is not deployed by `setup.sh`, and nothing is stateful.

### Hazards and Compatibility

- **Concurrency/atomicity:** none. The suite isolates its state in per-run temp dirs.
- **Migration/rollback:** a trivial revert of a two-line step.
- **Mixed-version/backward compatibility:** the step only runs for PRs whose scope is `substantive`. The core job already has that gate.
- **Idempotency/retry:** deterministic, with no network access.
- **Partial failure/recovery:** if the suite turns out to be Linux-sensitive on the hosted runner, fix the test fixture in the same PR. Do not mark the step `continue-on-error`.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-browser-qa-helper.sh            # local: 23/23 passed
node --test .agents/scripts/tests/test-ci-workflow-timeouts.mjs  # workflow contract still valid
```

- **Surface mapping:** the local run proves the suite is green. The PR's own `Framework Validation (core)` log proves it runs and passes on `ubuntu-latest`.
- **Broad verification trigger:** not required.

### Scope Boundaries

**Hard boundaries:** do not change `affected-script-tests` or `affected-tests-helper.sh`; selection gaps there are tracked separately. Do not change any product scripts.

### Files Scope

- `.github/workflows/code-quality.yml`

## Acceptance Criteria

- [ ] The PR's `Framework Validation (core)` job runs a `Browser QA Helper Regression (GH#39173)` step whose log shows `Results: 23/23 passed, 0 failed`, and the `Framework Validation` aggregator passes.
- [ ] Regression guarantee: the step has no `continue-on-error`, so a failing case fails the required context. Show this by inspection of the step YAML in the PR diff. Every other existing core-shard step is unchanged.

## Relevant Files

- `.github/workflows/code-quality.yml:398-614` (job `framework-validation-core`) and `:763-791` (aggregator)
- `.agents/scripts/tests/test-browser-qa-helper.sh`

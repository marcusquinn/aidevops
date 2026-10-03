<!-- aidevops:brief-schema=v2 -->

# t18544: Release: retry npm attestation verification through registry propagation lag

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Found while monitoring the v3.37.30 release (PR #32998). Publish run 36525940098 failed `Verify npm publication` on a transient attestation 404, and needed a manual `aidevops release reconcile 32994` to converge. Issue: GH#32999.

## What

Make the `Verify npm publication` step in `.github/workflows/publish-packages.yml` tolerate npm registry propagation lag for provenance attestations. It should retry the attestation-bundle fetch within a fixed bound instead of failing the whole publish run on the first 404. Every existing provenance and integrity assertion must stay exactly as strict as it is today.

## Why

- **v3.37.30** (run 36525940098, 2026-09-29):
  - The 12-attempt `npm view` metadata loop passed.
  - `npm --prefix "$AUDIT_DIR" audit signatures --json --include-attestations` (workflow line 282) then failed once at 05:27:44Z with `npm error 404 Not Found - GET https://registry.npmjs.org/-/npm/v1/attestations/aidevops@3.37.30`.
  - The same URL returned HTTP 200 at 05:29:39Z.
  - The reconcile recovery run 36526540995 passed unchanged.
- **v3.37.13** (run 36372969912, 2026-09-28): the metadata loop (`RETRY_DELAYS=(5 5 10 10 15 15 30 30 45 45 60)`, about 4.5 minutes) timed out with `npm did not converge to the exact package identity`.
- Each failure leaves the release lane in `remote-publication` without a terminal receipt. A human or primary session must then inspect the run and reconcile, which breaks the unattended release path.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: a single workflow step plus its static assertions. Not `tier:simple`, because retry logic around a provenance gate must preserve fail-closed semantics exactly, and it needs careful classification of which npm errors count as transient.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/publish-packages.yml:274-295` — wrap `npm install --prefix "$AUDIT_DIR" ...` plus `npm ... audit signatures --json --include-attestations` in a bounded retry. Retry only when the combined output matches the attestation endpoint 404 (`E404` with `/-/npm/v1/attestations/aidevops@${RELEASE_VERSION}`).
- `EDIT: .github/workflows/publish-packages.yml:241-242,265` — optionally extend `RETRY_DELAYS` modestly (for example, append `60 90`) and raise the `attempt` bound to match. The trigger is the v3.37.13 metadata-convergence timeout.
- `EDIT: .agents/scripts/tests/test-release-publication-workflows.sh:118-137` — update the static assertion for the `RETRY_DELAYS` literal if it changes, and add an assertion that the attestation retry exists and is scoped to the 404 signature.

### Complete Write Surface

- **Callers/readers:** the step runs only inside the `Publish Release` workflow (`.github/workflows/publish-packages.yml`). `aidevops release reconcile` (`.agents/scripts/full-loop-release-reconcile.sh`) re-dispatches this same workflow for recovery. It reads only the job conclusion, never step internals.
- **Writers/mutation paths:** none outside the workflow file. The step writes only to `$RUNNER_TEMP` (`AUDIT_DIR`, removed by the existing `cleanup_audit` trap).
- **Existing verification/tests:** `.agents/scripts/tests/test-release-publication-workflows.sh` statically asserts the step name (L118), the `RETRY_DELAYS` literal (L120) and the audit command literal (L137). The `.agents/scripts/tests/test-full-loop-release-reconcile*.sh` suite covers the reconcile path. The production evidence is the `Verify npm publication` step log of the next `Publish vX` run.
- **Schemas/config:** none. The retry delays are inline bash arrays, matching the existing `RETRY_DELAYS` pattern.
- **Generated/deployed mirrors:** none. The workflow is consumed directly by GitHub Actions; `setup.sh` does not deploy `.github/`.
- **Migrations/backfills:** N/A because no persisted state or schema changes: the workflow is stateless per run, and `.agents/scripts/full-loop-release-reconcile.sh` reads only run conclusions.
- **Cleanup/rollback paths:** revert the PR. The existing `cleanup_audit` trap still removes `AUDIT_DIR` on every exit path, including retries; recreate `AUDIT_DIR` per attempt or clear it between attempts.

### Implementation Steps

1. Extract the `npm install` + `audit signatures` pair into a small bash function inside the `run:` block (for example `_fetch_audit_json`). It returns the audit JSON on success and non-zero with the combined output captured in a variable on failure.
2. Loop up to about 6 attempts, with delays such as `10 20 30 60 90` (about 3.5 minutes in total):
   - On failure, retry only if the output matches both `E404` and `/-/npm/v1/attestations/aidevops@${RELEASE_VERSION}`.
   - Any other failure prints the output and exits 1 immediately.
   - After the final attempt, emit `::error::npm attestation bundle did not propagate for $RELEASE_VERSION` and exit 1.
3. Leave every `jq -e` assertion after `AUDIT_JSON=` (L283-323+) byte-for-byte unchanged. They run once, on the successful audit JSON.
4. Optionally extend the metadata `RETRY_DELAYS`/`attempt` bounds (step 2 of Files to Modify), keeping the per-attempt `.version`/`.dist.integrity`/`.dist.shasum` checks.
5. Update the static test assertions, then run the verification below.

### Hazards and Compatibility

- **Concurrency/atomicity:** a single job step with no shared state. Concurrent release runs already serialize on the release concurrency group in the workflow, and nothing here changes it.
- **Migration/rollback:** no persisted state; roll back with a plain revert.
- **Mixed-version/backward compatibility:** the reconcile helper reads only the job conclusion, and older checkouts running the old workflow keep failing fast exactly as today. Static test literals must stay in sync with the workflow in the same PR.
- **Idempotency/retry:** `npm install` into a fresh or cleared `AUDIT_DIR` is idempotent. The retry is read-only against the registry and never republishes.
- **Partial failure/recovery:** if the bound is exhausted, the step fails exactly as today, and `aidevops release reconcile <PR>` remains the recovery path. A non-404 npm error, an `invalid`/`missing` audit entry or a provenance mismatch must never be retried or masked.

### Complexity Impact

- **Target function:** inline `run:` script of the `Verify npm publication` step (not a shell function gate target).
- **Current line count:** about 95 lines (L239-333).
- **Estimated growth:** +20 lines.
- **Projected post-change:** about 115 lines of YAML-embedded bash. This is not subject to the 100-line function gate, which applies to `.sh` functions.
- **Action required:** keep the retry in one small named function to limit nesting.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-release-publication-workflows.sh
bash .agents/scripts/tests/test-full-loop-release-reconcile.sh
command -v actionlint >/dev/null && actionlint .github/workflows/publish-packages.yml
git diff origin/main -- .github/workflows/publish-packages.yml
```

- **Surface mapping:** `test-release-publication-workflows.sh` proves the step name, the delay literals and the retry scoping in `.github/workflows/publish-packages.yml` (mixed-version hazard: literals stay in sync). `test-full-loop-release-reconcile.sh` proves the recovery path in `.agents/scripts/full-loop-release-reconcile.sh` is unaffected (partial-failure hazard). `actionlint` validates the workflow syntax. The `git diff` review proves that no `jq -e` assertion line changed (fail-closed provenance gate hazard).
- **Broad verification trigger:** Not required. This touches release infrastructure, but only additive retry control flow inside one step, with no shared config or root tooling.

### Scope Boundaries

**Hard boundaries:** do not remove or relax any provenance, subject-digest, repository, workflow-path, ref or builder-id assertion. Do not retry on `invalid`/`missing` audit entries or on non-404 npm errors.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.github/workflows/publish-packages.yml`
- `.agents/scripts/tests/test-release-publication-workflows.sh`

## Acceptance Criteria

- [ ] An `E404` from `/-/npm/v1/attestations/aidevops@<version>` is retried within a fixed bound instead of failing on the first attempt.

  ```yaml
  verify:
    method: codebase
    pattern: "npm/v1/attestations"
    path: ".github/workflows/publish-packages.yml"
  ```

- [ ] Negative/regression: a non-404 npm error, an `invalid` or `missing` audit entry, or any provenance-binding mismatch still fails the step without retrying. No existing `jq -e` assertion is removed or relaxed.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-release-publication-workflows.sh"
  ```

- [ ] The release reconcile path is unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-release-reconcile.sh"
  ```

- [ ] After merge, the next release's `Publish vX` run passes `Verify npm publication` without a manual reconcile. This is observed at the next release, not in this PR.

## Context & Decisions

- Retrying only the attestation 404 keeps the gate strict: npm serves the attestation bundle from a separate endpoint that can lag the packument by about 2 minutes. Any other failure class stays fatal.
- The fix lives in the workflow rather than in the reconcile helper, so ordinary releases converge unattended and reconcile stays a true exception path.

## Relevant Files

- `.github/workflows/publish-packages.yml:234-333` — `Verify npm publication` step
- `.agents/scripts/tests/test-release-publication-workflows.sh:118-137` — static assertions
- `.agents/scripts/full-loop-release-reconcile.sh` — recovery path (read-only for this task)

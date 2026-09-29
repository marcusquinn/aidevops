<!-- aidevops:brief-schema=v2 -->

# t18512: Tolerate asynchronous npm publication during release verification

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Backfill the stranded brief for #32749 following the v3.37.13 release processing lag.

## What

Allow a correct npm release 5–10 minutes to become registry-visible without abandoning Homebrew/postflight; still reject mismatched package identity.

## Why

Run 36372969912 published successfully at 03:16:45Z, but the fixed verification window ended at 03:21:20Z; npm listed the exact release at 03:22:54Z. The failed job skipped later release steps.

## Tier

**Selected tier:** `tier:standard`

Release identity/integrity gating needs careful fail-closed handling.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/publish-packages.yml` — extend `Verify npm publication` convergence to around 15 minutes with capped retries, or use an existing retryable/deferred release-reconcile path.

### Complete Write Surface

- **Callers/readers:** `.github/workflows/publish-packages.yml` Homebrew and postflight steps depend on npm verification success; release reconciliation reads deferred outcomes if that alternative is chosen.
- **Writers/mutation paths:** `.github/workflows/publish-packages.yml` publishes npm before verification; this change affects wait/exit semantics, not published artifact contents.
- **Existing verification/tests:** workflow lint (`actionlint` or repository workflow lint) and the next release run; inspect registry identity checks.
- **Schemas/config:** `.github/workflows/publish-packages.yml` has inline retry delays; do not add secrets or change package metadata.
- **Generated/deployed mirrors:** `.github/workflows/publish-packages.yml` is executed directly by Actions; no generated mirror.
- **Migrations/backfills:** N/A because no persistent format changes and manual reconcile already handled the affected release.
- **Cleanup/rollback paths:** `git revert` returns to the shorter verification window.

### Implementation Steps

1. Inspect current `Verify npm publication` retry delays and `Create or reconcile GitHub release` deferred handling.
2. Extend only propagation time or safely reuse release reconciliation for timeout; retain exact integrity/shasum/provenance checks.
3. Run workflow lint and inspect the next release execution for eventual convergence and downstream steps.

### Hazards and Compatibility

- **Concurrency/atomicity:** waiting must not issue a second npm publish.
- **Migration/rollback:** no persistent schema or backfill.
- **Mixed-version/backward compatibility:** unchanged package identity and workflow job outputs.
- **Idempotency/retry:** eventual registry visibility permits the original release lane to finish.
- **Partial failure/recovery:** a mismatch still fails closed; a bounded timeout remains observable/reconcilable.

### Verification Before Dispatch

```bash
actionlint .github/workflows/publish-packages.yml
git diff --check
```

- **Surface mapping:** workflow lint checks YAML and shell expressions; next release run demonstrates 5–10 minute propagation recovery and unchanged mismatch safety.
- **Broad verification trigger:** release workflow is changed; run the repository workflow gate in addition to scoped lint if required by CI policy.

### Scope Boundaries

**Hard boundaries:** do not weaken exact integrity, shasum or provenance checks; never republish the existing release to test this.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve any PR and use the structured runtime/Pulse intake if scope expansion is required.

### Files Scope

- `.github/workflows/publish-packages.yml`

## Acceptance Criteria

- [ ] A correctly published npm version taking 5–10 minutes to converge reaches Homebrew and postflight without manual reconcile.

  ```yaml
  verify:
    method: codebase
    pattern: "RETRY_DELAYS"
    path: ".github/workflows/publish-packages.yml"
  ```

- [ ] Negative/regression: incorrect identity/integrity/shasum/provenance still fails closed.

  ```yaml
  verify:
    method: codebase
    pattern: "shasum"
    path: ".github/workflows/publish-packages.yml"
  ```

- [ ] Workflow lint passes on the changed file.

## Context & Decisions

- The registry delay is asynchronous publication processing, not a publish error; waiting longer is preferable to changing integrity checks.

## Relevant Files

- `.github/workflows/publish-packages.yml` — npm verification and deferred release handling.

<!-- aidevops:brief-schema=v2 -->

## What

Cloudron package monitor issues (r916 upstream, r917 compatibility) pass the `gh_create_issue` auto-dispatch scope gate again. Their `## Files Scope` lists only exact repository-relative paths, and the path descriptions move to a sibling `## File notes` section.

## Why

Since the stricter scope gate (GH#32880/GH#33243), `gh_create_issue` rejects Files Scope lines that have text after the path. `_cloudron_monitor_create_issue` wrote lines such as `` - `CloudronManifest.json` — package and upstream version metadata. `` and `` - `Dockerfile` or `Dockerfile.cloudron` — ... ``. Every finding therefore failed with `auto-dispatch issue not created: Files Scope heading is present but no line matches the accepted shape`. A manual r916 run on 2026-10-08 confirmed that NetBird v0.80.0, AI DevOps Worker v3.38.33 and Buzz v0.5.27 were all rejected.

## How

### Files to Modify

- `EDIT: .agents/scripts/cloudron-package-monitor-helper.sh` — add `_cloudron_monitor_files_scope` (path-only lines; picks `Dockerfile.cloudron` only when `Dockerfile` is absent; lists the existing `CHANGELOG`/`CHANGELOG.md`, defaulting to `CHANGELOG.md`), and move descriptions into `## File notes`.

### Complete Write Surface

- **Callers/readers:** `_cloudron_monitor_apply_finding` calls `_cloudron_monitor_create_issue`, which is used by both `upstream` and `compatibility`.
- **Writers/mutation paths:** only the issue body temp file under `${AIDEVOPS_TEMP_DIR}`.
- **Existing verification/tests:** `.agents/scripts/tests/test-cloudron-package-monitor.sh` ("upstream issue has canonical files scope").
- **Schemas/config:** N/A because the body format is consumed only by the scope gate in `.agents/scripts/pre-dispatch-validator-lib-brief-scope.sh`.
- **Generated/deployed mirrors:** the deployed `~/.aidevops/agents/scripts/` copy, updated on release.
- **Migrations/backfills:** N/A because the change affects only issues created after deploy; the three pending findings were filed manually with the fixed code.
- **Cleanup/rollback paths:** revert `.agents/scripts/cloudron-package-monitor-helper.sh`.

### Hazards and Compatibility

- **Concurrency/atomicity:** unchanged.
- **Migration/rollback:** none.
- **Mixed-version/backward compatibility:** the dedup fingerprint marker is unchanged, so issues filed by the old format still deduplicate.
- **Idempotency/retry:** unchanged; existing fingerprints are detected before creation.
- **Partial failure/recovery:** a rejected body still creates no issue, and the next run retries.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/cloudron-package-monitor-helper.sh
bash .agents/scripts/tests/test-cloudron-package-monitor.sh
bash .agents/scripts/cloudron-package-monitor-helper.sh upstream --apply
```

- **Surface mapping:** the production `--apply` run proves the gate accepts the body; the test proves the scope heading and fingerprint are kept.

### Files Scope

- `.agents/scripts/cloudron-package-monitor-helper.sh`

## Acceptance Criteria

- [ ] `cloudron-package-monitor-helper.sh upstream --apply` creates auto-dispatch issues without a scope-gate rejection.
- [ ] No Files Scope line produced by the monitor has text after the path (regression: the gate never rejects the monitor body).

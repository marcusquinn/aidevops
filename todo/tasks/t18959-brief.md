# t18959: fix(update): .aidevops.json migration issue fails when target repo lacks tier:simple label

## Origin

Observed interactively during `aidevops update` to v3.39.164 (2026-11-10). One initialized project produced:

```text
[INFO] [INFO] auto-dispatch label present — skipping self-assignment per t2157
could not add label: 'tier:simple' not found
[aidevops][gh-write-helper][ERROR] GitHub write failed (exit 1).
[WARN] Tracked .aidevops.json needs a linked-worktree migration; queueing failed
```

The update itself completed (21 projects synced); only the migration issue for that one repo was not filed. It will fail again on every update until fixed.

## What

`_project_config_write_migration_issue()` must succeed in a managed repo that has never had the canonical aidevops label set synced, instead of failing on a missing `tier:simple` (or `auto-dispatch`) label.

## Why

The migration (stop tracking `.aidevops.json`, preserving local bytes) is never queued for repos missing the label, so they stay in the unsafe tracked-config state indefinitely, and every `aidevops update` repeats an error the user cannot act on.

## Tier

`tier:simple` — one function in one shell library; deterministic fix with an existing helper.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh:147-156` — `_project_config_write_migration_issue()` passes `--label "auto-dispatch" --label "tier:simple"` to `gh-write-helper.sh issue create`.

### Reference pattern

- `.agents/scripts/label-sync-helper.sh` — `canonical_label_definition()` (line ~281), `_apply_label()` (line ~382, idempotent `gh label create --force`), and `cmd_sync --repo <slug>` (line ~541). The canonical `tier:simple` definition is at line ~100.

### Implementation Steps

1. Before `issue create`, ensure both labels exist in `$repo_slug` using the canonical definitions from `label-sync-helper.sh` (preferred: a bounded, single-repo, existing-label-safe call such as `label-sync-helper.sh sync --repo "$repo_slug"`, or a new small `ensure <repo> <label>...` subcommand reusing `canonical_label_definition` + `_apply_label`). Do not hard-code colours/descriptions in the project-config lib.
2. If ensuring labels fails (no label write permission, rate limit), fall back to creating the issue with `auto-dispatch` only, and if that also fails, keep the existing `queueing failed` warning. Never fail `aidevops update`.
3. Keep `_project_config_migration_exists` dedup behaviour unchanged so a retry after the fix cannot create duplicates.

### Hazards

- `aidevops update` loops over many repos; any label sync must be per-repo bounded and must not run for repos where `_project_config_migration_needed` returned non-zero.
- Respect the existing `_PROJECT_CONFIG_MIGRATION_MAX_REPOS` queue limit.
- Keep private repo names out of logs/issue bodies that go to public repos.

### Files Scope

- `.agents/scripts/aidevops-cli/aidevops-project-config-lib.sh`
- `.agents/scripts/label-sync-helper.sh`

## Acceptance Criteria

- In a repo lacking `tier:simple`, the migration path creates the labels (or falls back) and files exactly one migration issue.
- In a repo that already has the labels, behaviour is unchanged (no extra label writes beyond idempotent `--force`).
- `aidevops update` still exits 0 when label creation is not permitted.
- ShellCheck clean; existing `.agents/scripts/tests/test-update-project-config-safety.sh` passes.

## Verification

- `shellcheck .agents/scripts/aidevops-cli/aidevops-project-config-lib.sh .agents/scripts/label-sync-helper.sh`
- `bash .agents/scripts/tests/test-update-project-config-safety.sh`
- Runtime: run `aidevops update` (or the project-sync path) on a machine with an initialized repo that tracks `.aidevops.json` and lacks `tier:simple`; confirm `Queued tracked .aidevops.json migration` instead of `queueing failed`.

## What

Routine r924 (`cloudron-release-approval-helper.sh process --apply`) exits 1 on every run since v3.39.104. It cannot create the release approval request for the held worker bump PR, and the same failure blocks unrelated supersession of obsolete held bump PRs.

## Why

Observed after the v3.39.104 deploy (GH#36268 / PR #36269 path):

- `pulse.log`: `routine r924: script exited with code 1` on the latest run.
- A manual `process --apply` reproduction printed `Could not add label: 'no-auto-dispatch' not found`.
- The target package repository has no `no-auto-dispatch` label. `release_request()` provisions only `release-approval-required` (with an unconditional `gh label create --force` write on every request), then calls `gh_create_issue ... --label no-auto-dispatch`. `gh_create_issue` deliberately never creates caller-supplied labels (GH#34003), so creation fails.
- This leaves the held PR half-processed. `hold-for-review` and `release-approval-required` are applied but no approval issue exists. The existing retry guard (`release_request` line ~159) allows the next run to resume.
- Coupling defect: `release_held_target()` returns 1 when the request fails, so `release_reconcile_held()` aborts before its supersede loop. Older held PRs whose reason is independent of the request (`main already bundles upstream X`) are never superseded while one request keeps failing.
- Same defect class as GH#34071 (dispatch-control label absent in a managed repository; edit path). `label-sync-helper.sh` is not scheduled, so managed package repositories drift from the canonical system labels.

## How

1. `.agents/scripts/managed-label-provisioning-lib.sh`: add a canonical release-approval label set (`release-approval-required`, `hold-for-review`, `no-auto-dispatch`; colours and descriptions mirror `label-sync-helper.sh` `SYSTEM_LABELS` and the current helper) plus `managed_labels_ensure_release_approval_set`, following `managed_labels_ensure_approval_set`.
2. `.agents/scripts/cloudron-release-approval-helper.sh` `release_request()`: replace the unconditional `gh label create release-approval-required --force` with the managed set, using `_gh_managed_label_names_snapshot` / `_gh_managed_label_create_runner` (pattern: `approval-helper.sh` `_approval_ensure_lifecycle_labels`). Provision before any PR label edit, so a provisioning failure leaves no half-applied hold. A converged repo then costs one label read and no writes.
3. `release_held_target()` / `release_reconcile_held()`: when the request fails, still emit the target line (`requested=false`), count the failure, and continue the supersede loop. Request-independent supersession (`on_main`) proceeds. Request-dependent supersession still waits for a real request.

### Files Scope

- `.agents/scripts/managed-label-provisioning-lib.sh`
- `.agents/scripts/cloudron-release-approval-helper.sh`
- `.agents/scripts/tests/test-cloudron-release-approval.sh`
- `.agents/scripts/tests/test-managed-label-provisioning.sh`

## Verification

- `shellcheck` clean on both changed scripts.
- `bash .agents/scripts/tests/test-cloudron-release-approval.sh` and `bash .agents/scripts/tests/test-managed-label-provisioning.sh` pass.
- Production: after deploy, r924 (or the deployed `process --apply`) creates the approval request for the newest held PR, supersedes older held bumps per its dry-run reasons, and r924 logs `script completed successfully`.

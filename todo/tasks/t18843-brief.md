# fix(workflows): permission rollout check must not demand caller edits when the reusable permission union is unchanged

## What

`check_permission_rollouts` in
`.agents/scripts/tests/test-reusable-workflow-permission-contracts.sh` treats
any per-job permission increase in a `*-reusable.yml` workflow as a rollout
event. It does this even when the workflow's overall permission union is
unchanged. A new job that only uses permissions the union already has must
then change the caller template and name a `sync-workflows --apply` rollout.
The template already grants exactly the union, as the caller-equality check in
the same script enforces, so the only way to pass is a meaningless template
edit.

## Why

- PR #36213 (GH#36212) adds a `quota-audit` job with `contents: read` to
  `.github/workflows/issue-sync-reusable.yml`. The union already includes
  `contents: write`, and the caller-equality check passes. Framework
  Validation still fails (Actions run 41187696326, job 124498149160):
  `FAIL issue-sync: permission increase requires updating .agents/templates/workflows/issue-sync-caller.yml`
  plus the named-rollout failure. Local reproduction:
  `BASE_SHA=c7cea6944a… HEAD_SHA=b375ea9514… bash .agents/scripts/tests/test-reusable-workflow-permission-contracts.sh`.
- For a new job, `old_job` is `{}`, so `old_permissions` falls back to the
  old top-level permissions, which are usually absent. Every new reusable job
  with any permission therefore counts as an "increase".
- Installed callers grant permissions at the calling job, equal to the
  reusable union. A job whose permissions are within the unchanged union
  cannot cause the `startup_failure` that GH#35096 (`loc-badge`) guards
  against.

## How

1. In `check_permission_rollouts`, keep the union comparison
   (`permission_increased(before, after)`) as the rollout trigger.
2. Replace the per-job loop's effect: a per-job increase triggers a rollout
   only when the new job level exceeds the **base union** (`before`). This is
   equivalent to the union growing, so the loop can be dropped. Alternatively,
   compare each new job level to `before` instead of the old job. Remove or
   correct the comment "A job can gain permissions already used by another
   job ... still requires an explicit rollout plan".
3. Extend `assert_rollout_contract` or add a small in-script assertion
   (existing pattern: `assert_discovery_contract`) so that adding a new job
   whose permissions are a subset of the existing union yields no rollout
   failure, while a job that adds a permission not in the union still fails.

## Files Scope

- .agents/scripts/tests/test-reusable-workflow-permission-contracts.sh

## Acceptance

- A new reusable job with permissions within the base union produces no
  `permission increase` failure.
- A job that raises the union, for example by adding `actions: write` where
  the union has only `actions: read`, still requires the caller template
  update and the named rollout.
- Existing caller-equality and discovery assertions still pass.

## Verification

```bash
shellcheck .agents/scripts/tests/test-reusable-workflow-permission-contracts.sh
bash .agents/scripts/tests/test-reusable-workflow-permission-contracts.sh
# With PyYAML available, replay the PR #36213 diff:
BASE_SHA=<merge-base sha> HEAD_SHA=<PR #36213 head sha> PR_BODY=none \
  bash .agents/scripts/tests/test-reusable-workflow-permission-contracts.sh
```

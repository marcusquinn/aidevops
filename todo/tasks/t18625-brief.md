## What

Follow-up from GH#34022 / PR #34023: the Actions-unavailable merge gate still blocks when Qlty reports its out-of-minutes outage as a **commit status** rather than a check run.

## Observed

On a private repository registered `actions: unavailable`, with a valid exact-head local-verification receipt, `repo_actions_verify_local()` returns 1 silently. The head's commit statuses include:

- context `qlty check`, state `error`, description `Qlty did not run because you are out of minutes.`, creator `qltysh[bot]` (type `Bot`).

PR #34023 classifies this outage only for check runs (`ci_check_run_indicates_billing_outage`, app slug `qlty`). The statuses branch in `repo_actions_verify_local()` still requires every latest status to be `success` or `pending`, and prints no diagnostic.

## How

- `.agents/scripts/ci-infra-signature-lib.sh`: add `ci_commit_status_indicates_quota_outage` taking one status JSON object; true only when `creator.login == "qltysh[bot]"`, `creator.type == "Bot"`, state is `error` or `failure`, and the description is exactly the Qlty no-run message (same anchored regex as the check-run path).
- `.agents/scripts/repo-actions-capability-lib.sh`: in `repo_actions_verify_local()`, take the latest status per context; allow `success`/`pending`, allow failures that pass the classifier, and print `BLOCKED: non-billing terminal status: <context> (<state>, creator: <login>)` for any other.
- `.agents/scripts/tests/test-repo-actions-capability.sh`: cover the Qlty status outage passing, the same message from a non-Qlty creator blocking, and a Qlty status with a real finding blocking.

### Files Scope

- `.agents/scripts/ci-infra-signature-lib.sh`
- `.agents/scripts/repo-actions-capability-lib.sh`
- `.agents/scripts/tests/test-repo-actions-capability.sh`

## Verification

- `bash .agents/scripts/tests/test-repo-actions-capability.sh`
- `shellcheck .agents/scripts/ci-infra-signature-lib.sh .agents/scripts/repo-actions-capability-lib.sh .agents/scripts/tests/test-repo-actions-capability.sh`

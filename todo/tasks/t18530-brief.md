<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18530: classify Actions billing-blocked checks as capability failures in pulse CI repair

## Origin

- **Created:** 2026-09-28
- **Session:** opencode interactive (Build+)
- **Created by:** ai-interactive (maintainer review of GH#32869)
- **Parent task:** none
- **Conversation context:** GH#32869 reports that Pulse sent a CI-repair worker for PR checks that failed immediately because the organisation had zero Actions minutes. The maintainer review ([comment](https://github.com/marcusquinn/aidevops/issues/32869#issuecomment-5878379013)) confirmed that billing classification differs between two code paths. It excluded a required-check bypass and a persisted per-repo capability setting.

## What

`_dispatch_ci_fix_worker` never starts a code-repair worker, and never requests an infrastructure rerun, for a failed check whose job GitHub refused to run for billing or spending reasons. The billing detector lives in one shared lib used by both the failure miner and the CI-repair path.

## Why

`gh-failure-miner-helper.sh:234-276` already detects billing exhaustion from check-run annotations ("account payments have failed" / "spending limit needs to be increased"). `_ci_check_url_has_infra_failure_log` (`pulse-merge-feedback-ci-repair.sh:69-97`) only greps `gh run view --log-failed`. That output is empty for a job that never started, so the check is treated as actionable and a repair worker is dispatched (lines 110-140, 333).

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/ci-infra-signature-lib.sh` — contains `CI_BILLING_OUTAGE_PATTERN` and `ci_check_run_annotations_indicate_billing_outage <repo> <check_run_id>`, taken from `gh-failure-miner-helper.sh:234-249`. Guard against double-sourcing, and use explicit returns.
- `EDIT: .agents/scripts/gh-failure-miner-helper.sh:11,234-249,315` — source the lib. `job_annotations_indicate_billing_outage` delegates to it, and the billing log grep uses the shared pattern. Behaviour is unchanged.
- `EDIT: .agents/scripts/pulse-merge-feedback-ci-repair.sh:9-14,110-140` — source the lib. Add `_ci_check_url_has_billing_block <repo> <url>` (Actions job ID = check-run ID from `/job/<id>`). In `_ci_actionable_failed_checks_markdown`, check billing first and log `classified as Actions billing/spending block — no code repair, no rerun`, without calling `_pmrc_rerun_infrastructure_check`.
- `EDIT: .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh` — add a `billing_blocked` scenario: empty `run view` output, and a gh route for `api repos/owner/repo/check-runs/456/annotations` that returns the billing annotation. Expect no repair dispatch, no rerun call, and the log line. Load the lib and the new function in `define_ci_dispatch_helpers`.

### Complete Write Surface

- **Callers/readers:** `_dispatch_ci_fix_worker` is the only caller of `_ci_actionable_failed_checks_markdown`. The miner's `classify_failed_job_signature` calls `job_annotations_indicate_billing_outage`. `rg -n "job_annotations_indicate_billing_outage|_ci_actionable_failed_checks_markdown|_ci_check_url_has_infra_failure_log" .agents/scripts` lists all uses.
- **Writers/mutation paths:** `_dispatch_ci_fix_worker` issue-body feedback writes, repair-worker dispatch and `_pmrc_rerun_infrastructure_check` reruns are skipped for billing-blocked checks. Nothing new is written.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh`, `.agents/scripts/tests/test-ci-failure-pattern-detection.sh`.
- **Schemas/config:** N/A because no config keys are added and billing is derived from live annotations.
- **Generated/deployed mirrors:** `~/.aidevops/agents/scripts/` via `setup.sh`. The new lib is deployed with the scripts directory.
- **Migrations/backfills:** N/A because the change is stateless.
- **Cleanup/rollback paths:** `git revert` of the PR restores the previous classification.

### Implementation Steps

1. Create `ci-infra-signature-lib.sh` with the shared pattern and annotation detector.
2. Make the miner source it and delegate. Keep the miner's function names.
3. Source it from `pulse-merge-feedback-ci-repair.sh` and add `_ci_check_url_has_billing_block`. Call it first in `_ci_actionable_failed_checks_markdown`, and skip both repair and rerun on a match.
4. Add the `billing_blocked` routing test scenario.

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A because classification is a pure read per check; the existing head-bound lease still guards dispatch.
- **Migration/rollback:** N/A because there is no state; a revert restores repair dispatch for billing failures.
- **Mixed-version/backward compatibility:** the merge gate is unchanged. Repos without required contexts already merge (`pulse-merge-required-checks.sh:1619`); required checks that cannot run still block, which stays the repo owner's decision. Miner output is unchanged.
- **Idempotency/retry:** repeated passes re-read annotations and reach the same skip. No reruns are queued, so there is no churn.
- **Partial failure/recovery:** if the annotations read fails, the check falls back to the existing infra-log path (today's behaviour), so there is no new silent suppression. Cost: one annotations read per terminal failed required check, only on the repair path.

### Complexity Impact

- **Target function:** `_ci_actionable_failed_checks_markdown` (31 lines, threshold 100). It grows by about 5 lines. No action required.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh
bash .agents/scripts/tests/test-ci-failure-pattern-detection.sh
shellcheck .agents/scripts/ci-infra-signature-lib.sh .agents/scripts/pulse-merge-feedback-ci-repair.sh .agents/scripts/gh-failure-miner-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** the routing test covers dispatch suppression and the no-rerun rule; the ShellCheck targets cover the new lib and both consumers.
- **Broad verification trigger:** Not required.

### Files Scope

- .agents/scripts/ci-infra-signature-lib.sh
- .agents/scripts/gh-failure-miner-helper.sh
- .agents/scripts/pulse-merge-feedback-ci-repair.sh
- .agents/scripts/tests/test-pulse-merge-ci-repair-routing.sh
- todo/tasks/t18530-brief.md
- TODO.md

## Acceptance Criteria

- [ ] A failed required check with a billing annotation dispatches no repair worker and no rerun, and the classification is logged.
- [ ] Existing infra-log scenarios (timeouts, registry/API rate limits) and real code failures behave as before.
- [ ] The miner and the CI-repair path share one billing pattern and one detector.

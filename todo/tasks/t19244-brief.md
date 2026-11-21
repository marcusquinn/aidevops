## What

Route terminal-red required CI on worker PRs held **only** by the automation-owned runtime-pending `hold-for-review` to the existing CI fix-worker route. Keep the hold, and never merge from this path.

## Why

A held PR never reaches CI repair. `_pmp_stage_review_and_gates` calls `_check_pr_merge_gates` (`.agents/scripts/pulse-merge.sh`, around line 845). That calls `_pm_gate_origin_authority`, which returns 1 for every draft or `hold-for-review` PR (the `PR is draft or has hold-for-review` branch, around lines 747-770) before `_pmp_stage_required_checks` runs. The only `_route_pr_to_fix_worker ... "ci"` call is in `_pmp_stage_required_checks`, around line 1443.

Evidence, 2026-11-21: PR #39647 (worker, runtime-pending hold) was red on the required `Framework Validation (pulse-merge suites)` check at head `5f825e7b28` from 07:22Z to 08:13Z. Cause: `rg` is not installed on ubuntu runners. Pulse logged 4 hold skips and routed no CI repair; an interactive session fixed it.

t19241 (PR #39647, commit `2242189fde`) now defers the runtime-pending verifier notice until head CI is green. Runtime evidence binds to the exact head, so a verifier must not exercise a red head. Without this route, a red runtime-pending PR therefore waits for a human, which is the friction aidevops exists to remove. This route handles runtime-pending only. Other hold scopes stay human-gated.

## How

- In the held branch of `_pm_gate_origin_authority`, after the existing `_pmrp_route_held_pr` call, add one guarded call to a new helper, for example `_pmrp_route_held_ci_repair <pr> <repo> <linked_issue> <labels>`. Then still `return 1`.
- Put the helper in `.agents/scripts/pulse-merge-runtime-pending-notice.sh`, not `pulse-merge.sh`. `pulse-merge.sh` is near the 2000-line file gate; see commit `d9f939e170`.
- Route only when all of these hold:
  - the PR is not a draft;
  - it carries `origin:worker` or `origin:worker-takeover`;
  - `full-loop-helper.sh runtime-pending-notice <pr> <repo>` exits 0. Reuse it; it is the trust decision for "runtime-pending scope alone, no PR-only contract". Never copy that logic. `#aidevops:trust-boundary`;
  - `_check_required_checks_have_pending_or_in_progress` returns 1, so no required check is active;
  - `_required_checks_terminal_failure_names <repo> <pr> <head>` prints at least one name.
- Then call `_route_pr_to_fix_worker "$pr" "$repo" "$linked_issue" ci "$labels" "" "" "$head"`. Its `ci-feedback-routed` label and CI-drift ledger dedupe repeats.
- Check the downstream finalizer gates in `.agents/scripts/pulse-merge-feedback-finalizer.sh`. These calls run without `ignore_hold`, around lines 1363, 1528 and 1620: `_feedback_route_labels_allow_worker_route "$labels"`. These will likely refuse `hold-for-review`.
  - Pass `ignore_hold=1` only on the path that comes from this runtime-pending helper; for example, use an explicit env flag set and unset around the call.
  - Every other caller must keep refusing held PRs.
- The route must never remove `hold-for-review`. If routing closes and re-dispatches, the replacement worker PR carries its own runtime-pending declaration and hold. That is expected.

### Files Scope

- .agents/scripts/pulse-merge.sh
- .agents/scripts/pulse-merge-runtime-pending-notice.sh
- .agents/scripts/pulse-merge-feedback-finalizer.sh
- .agents/scripts/tests/test-pulse-merge-runtime-pending-notice.sh

## Acceptance

- A stubbed held runtime-pending `origin:worker` PR with terminal-red required checks routes exactly one CI fix per head. Pending checks route nothing.
- No route for any of these:
  - another hold scope (`release-approval-required`, a manual maintainer hold, an unrecorded scope, or a PR-only contract), meaning `runtime-pending-notice` exits 1;
  - draft;
  - `external-contributor`, `no-takeover` or `needs-maintainer-review`;
  - `origin:interactive` without takeover.
- `hold-for-review` is never removed by this path, and the held PR is never merged by it.
- `bash .agents/scripts/tests/test-pulse-merge-runtime-pending-notice.sh` and the pulse-merge suites pass; ShellCheck is clean; `complexity-regression-helper.sh check --base origin/main` reports no new violations.

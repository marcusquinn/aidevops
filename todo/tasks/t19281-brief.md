## What

Pulse leaves a held `runtime-pending` PR with Low or Medium declared risk waiting for a live interactive verifier, without any time limit. Since t19276 (GH#39831, released in v3.39.263), `commit-and-pr` refuses `runtime-pending` below Critical/High, because a Low/Medium PR merges on self-assessed evidence and a hold only parks unfinished work for a human. PRs held before that release keep the old state. Route them to an on-branch completion worker instead of an interactive verifier, and lift the hold once the body no longer declares `runtime-pending`.

## Why

- `_pmrp_route_held_pr` (`.agents/scripts/pulse-merge-runtime-pending-notice.sh:175-243`) never reads the declared risk. After `full-loop-helper.sh runtime-pending-notice` (`.agents/scripts/full-loop-helper-verify-runtime.sh:595-622`) returns a liftable notice and CI is green, it only messages live interactive sessions or writes an ATTENTION log line. Nothing completes the deferred steps or lifts the hold, so these PRs need a human to start an interactive session.
- Evidence (2026-11-22): in one managed private repository, 3 open PRs carry this state: 2 Low (data-only enrichment specs; deferred step "beta dry run and publication follow"), 1 Medium (an opt-in beta e2e spec; deferred step "live beta run with the ordinary test account (no credentials injected on this runner)"). All three were created on 2026-11-21/22, before v3.39.263 shipped t19276, and none has a route other than the `/decisions` queue (t19260).
- High/Critical holds still need a runtime verifier and are out of scope.

## How

1. In `_pmrp_route_held_pr`, after the notice is liftable and `_pmrp_head_ci_ready` returns 0 (line 212), read the declared risk level from the PR body. Reuse the existing body parsers in `.agents/scripts/full-loop-helper-risk.sh` (`_runtime_testing_metadata_from_body` and the `Risk level` parsing near line 630); do not write a new regex. Expose them through a read-only `full-loop-helper.sh` subcommand or by extending the `runtime-pending-notice` JSON with a `risk` field. The second option is preferred because pulse already calls it.
2. If the level is `runtime-pending` and risk is Low or Medium, skip the interactive notice. Route the PR with `_route_pr_to_fix_worker` (`.agents/scripts/pulse-merge-process.sh:1285`) using a new kind, for example `runtime-pending-legacy`. Keep the same worker/takeover-origin label gate as `_pmrp_route_held_ci_repair` (line 148, `_feedback_route_labels_allow_worker_route`) and mark the check `#aidevops:trust-boundary`. The worker prompt for that kind must say: complete the deferred steps quoted in the Verification line on the PR branch, then rerun `full-loop-helper.sh commit-and-pr` so the body is regenerated with self-assessed evidence. If a step needs a capability or secret this runner lacks, emit the brief's terminal blocker naming that capability or secret name (never its value), not `runtime-pending`.
3. Lift the hold when the body declares Low/Medium risk, no longer declares `runtime-pending`, and `_verify_runtime_hold_decision` returns `lift` (recorded scope runtime-pending alone, no PR-only contract). Post an audit comment that mirrors `_verify_runtime_audit_comment` (`.agents/scripts/full-loop-helper-verify-runtime.sh:563`) and recheck the head immediately before removing the label, as `verify-runtime` does. A PR-only, unrecorded or unreadable scope keeps the hold.
4. High/Critical holds keep the current interactive-verifier notice and CI repair route unchanged.
5. Placement: `full-loop-helper-risk.sh` is read-only reuse; edit it only to expose an existing parser. The new kind goes in the `_route_pr_to_fix_worker` dispatch case (`.agents/scripts/pulse-merge-process.sh:963-965`, routed labels at 1316-1318). Model its dispatcher and prompt on `_dispatch_ci_fix_worker` (`.agents/scripts/pulse-merge-feedback-ci-repair.sh:408`); a new sibling file is acceptable if that file is near the size gate.

### Files Scope

- `.agents/scripts/pulse-merge-runtime-pending-notice.sh`
- `.agents/scripts/full-loop-helper-verify-runtime.sh`
- `.agents/scripts/full-loop-helper-risk.sh`
- `.agents/scripts/pulse-merge-process.sh`
- `.agents/scripts/pulse-merge-feedback-ci-repair.sh`

## Acceptance

- A held, CI-green, Low/Medium `runtime-pending` PR with worker origin gets one completion-worker route per head within one merge pass, and no interactive notice.
- After that worker regenerates the body without `runtime-pending`, the next pass lifts `hold-for-review` with an audit comment, and the normal merge pass can merge the PR.
- High/Critical held PRs, external or no-takeover PRs, and PR-only or unrecorded hold scopes behave exactly as before.
- A completion worker that cannot run a deferred step ends with a terminal blocker that names the missing capability or secret, so the issue records why it is blocked.

## Verification

- `shellcheck -x` on every changed script.
- `.agents/scripts/tests/test-pulse-merge-runtime-pending-notice.sh` and `.agents/scripts/tests/test-full-loop-verify-runtime.sh` pass (`.agents/scripts/affected-tests-helper.sh run --base origin/main`).
- Product-path evidence in the PR: `full-loop-helper.sh runtime-pending-notice <PR> <repo>` output for a real held Low/Medium PR, showing the risk field and the route decision. Do not name private repositories in public PR text.

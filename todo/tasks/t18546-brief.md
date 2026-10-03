<!-- aidevops:brief-schema=v2 -->

# t18546: Pulse Dependabot intake: provision the dependencies label before creating intake issues and log the gh error

## Origin

- **Created:** 2026-09-29
- **Created by:** ai-interactive
- **Conversation context:** Found while monitoring pulse cycle `20260929T052653Z-87280` on aidevops 3.37.30, after the Dependabot-target deadlock fix (t18541, PR #32983) shipped. Issue: GH#33003.

## What

Make Dependabot intake create its worker issue on repositories that lack a `dependencies` label, and log why `gh_create_issue` failed whenever it does fail. Today every merge pass retries and silently fails for the same PRs.

## Why

- `~/.aidevops/logs/pulse.log` has 190 `[pulse-dependabot-intake] PR #N in marcusquinn/cloudron-netbird-app: worker issue creation failed` lines, all for that repo's 6 open Dependabot PRs (#118, #120, #131, #132, #151, #152), repeating on every merge pass.
- Verified root cause:
  - `_pulse_route_dependabot_pr_to_worker_issue` requests `--label "auto-dispatch,origin:worker,tier:standard,dependencies"` (`.agents/scripts/pulse-dependabot-intake.sh:597-600`).
  - The repo has the first three labels but not `dependencies`; its Dependabot PRs carry no labels, so GitHub never auto-created it.
  - `gh issue create --label` rejects unknown labels, and `gh_create_issue` provisions only the managed origin set (`.agents/scripts/shared-gh-wrappers-create.sh:1334-1368`).
- The label is load-bearing: `_pulse_dependabot_intake_election_rows` finds existing intake issues with `--label dependencies` (`.agents/scripts/pulse-dependabot-intake.sh:62-72`), so dropping it would break duplicate detection (#31618).
- The failure path discards `issue_output` (L601-605), which hid the cause. Each failed attempt also spends the preflight, hold, existing-issue and scope API calls (L538-581) for no outcome.

## Tier

**Selected tier:** `tier:standard`

`tier:standard`: a small change, but it alters automated issue creation that feeds auto-dispatch, and it adds a shared label-provisioning helper. It does not meet every `tier:simple` execution-contract condition in `reference/task-taxonomy.md`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/managed-label-provisioning-lib.sh:15-31,69-76` — add a `_MANAGED_DEPENDABOT_INTAKE_LABEL_SPECS` array (`"dependencies" "Pull requests that update a dependency file" "0366D6"`) and a `managed_labels_ensure_dependabot_intake_set` function modelled on `managed_labels_ensure_origin_set`.
- `EDIT: .agents/scripts/pulse-dependabot-intake.sh:514-612` — in `_pulse_route_dependabot_pr_to_worker_issue`, between the scope lookup (L576-581) and `gh_create_issue` (L597):
  - call `managed_labels_ensure_dependabot_intake_set "$repo_slug" _gh_managed_label_names_snapshot _gh_managed_label_create_runner`, guarded by `declare -F` like L534-537;
  - on failure, release the intake lock, log `dependencies label unavailable`, and return 1;
  - on `gh_create_issue` failure, append a one-line reason, sanitised and truncated to about 200 characters, from `issue_output` to the existing log line.
- `EDIT: .agents/scripts/tests/test-pulse-dependabot-intake.sh:42-140` — add stubs for the label snapshot/create runners next to the existing `gh_create_issue` stub (L122). Add cases for label absent (create once, then issue), label present (no create call) and provisioning failure (no issue, lock released).

### Complete Write Surface

- **Callers/readers:** `_pulse_route_dependabot_pr_to_worker_issue` is called from `.agents/scripts/pulse-merge.sh:516` (policy-ineligible), `:1514` (merge-conflict) and `:1590` (terminal-ci-failure); `.agents/scripts/tests/test-pulse-merge-issue-sync-authority.sh:70` stubs it. `_pulse_dependabot_intake_election_rows` (L55-86) and dispatch dedup read the `dependencies` label on intake issues.
- **Writers/mutation paths:** `_gh_managed_label_create_runner` (`.agents/scripts/shared-gh-wrappers-create.sh:1370-1379`) creates the repo label once; `gh_create_issue` creates the intake issue; `_pulse_dependabot_release_intake_lock` releases the lock on every exit path.
- **Existing verification/tests:** `.agents/scripts/tests/test-pulse-dependabot-intake.sh` (creation, dedup, election, hold, authenticity, scope, concurrency), `.agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh`, and the production signal `rg -c "worker issue creation failed" ~/.aidevops/logs/pulse.log`.
- **Schemas/config:** the managed label catalogue in `.agents/scripts/managed-label-provisioning-lib.sh` gains one spec set. The colour follows GitHub's default `dependencies` label; no other config.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`, and the pulse loads it through the runtime bundle after release.
- **Migrations/backfills:** N/A because no persisted state changes: the label is created on demand on the next intake attempt for each repo, and the 6 stuck PRs recover on the first pass after deploy.
- **Cleanup/rollback paths:** revert the PR. Created `dependencies` labels are harmless and can stay.

### Implementation Steps

1. Add the spec array and `managed_labels_ensure_dependabot_intake_set` to `.agents/scripts/managed-label-provisioning-lib.sh`, following `managed_labels_ensure_origin_set` (L69-76).
2. In `_pulse_route_dependabot_pr_to_worker_issue`, call it after the scope lookup and before creating the body file, releasing the lock on failure.
3. Add a sanitised one-line reason to the `worker issue creation failed` log line.
4. Extend `.agents/scripts/tests/test-pulse-dependabot-intake.sh` with the three label cases, then run the verification block.

### Hazards and Compatibility

- **Concurrency/atomicity:** provisioning runs under the existing per-PR intake lock. Two runners creating the same label concurrently get HTTP 422 on the second create, so treat a failed create followed by a snapshot that now contains the label as success, or rely on the next pass.
- **Migration/rollback:** no persisted state; roll back with a plain revert.
- **Mixed-version/backward compatibility:** older runners without the helper keep failing exactly as today. The `declare -F` guard must keep the intake working (fail-closed, no issue) if the provisioning library is not sourced.
- **Idempotency/retry:** `managed_labels_ensure_specs` snapshots labels first and creates only missing ones. Intake issue creation stays deduplicated by the marker and election logic.
- **Partial failure/recovery:** if label creation fails, no issue is created and the lock is released, so the next pass retries. Do not fall back to creating the issue without `dependencies`, because that would bypass duplicate detection.

### Complexity Impact

- **Target function:** `_pulse_route_dependabot_pr_to_worker_issue` in `.agents/scripts/pulse-dependabot-intake.sh`
- **Current line count:** 99 lines (L514-612; threshold: 100 lines for function-complexity)
- **Estimated growth:** +10 lines (provisioning call, lock release, log reason)
- **Projected post-change:** 109 lines without extraction (over threshold)
- **Action required:** extract a helper first, e.g. `_pulse_dependabot_create_intake_issue` covering L583-606 (temp body, provisioning, `gh_create_issue`, failure log), so the route function drops to about 80 lines.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/pulse-dependabot-intake.sh .agents/scripts/managed-label-provisioning-lib.sh
bash .agents/scripts/tests/test-pulse-dependabot-intake.sh
bash .agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh
```

- **Surface mapping:** `shellcheck` covers both modified scripts, including the extracted helper. `test-pulse-dependabot-intake.sh` proves label provisioning, the no-create short-circuit, provisioning failure with lock release, and unchanged dedup/election/hold/authenticity behaviour in `.agents/scripts/pulse-dependabot-intake.sh` (idempotency, concurrency and partial-failure hazards). `test-pulse-merge-trusted-dependabot.sh` proves the merge-pass caller path is unchanged (mixed-version hazard).
- **Broad verification trigger:** Not required. No shared config, root tooling, dependency graph or release infrastructure changes.

### Scope Boundaries

**Hard boundaries:** do not change the requested label set, the intake marker, election/dedup logic, Dependabot authenticity checks or maintainer-hold handling. Never create the intake issue without the `dependencies` label.

**AI brief owner:** marcusquinn (maintainer), interactive session.

**Recovery:** preserve the current PR and use the structured runtime request and Pulse intake in `reference/worker-discipline.md` when local recovery is unsafe.

### Files Scope

- `.agents/scripts/pulse-dependabot-intake.sh`
- `.agents/scripts/managed-label-provisioning-lib.sh`
- `.agents/scripts/tests/test-pulse-dependabot-intake.sh`
- `TODO.md`

## Acceptance Criteria

- [ ] On a repo without a `dependencies` label, intake provisions it once and creates the worker issue with all four labels.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dependabot-intake.sh"
  ```

- [ ] On a repo that already has the label, no label-create call is made.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dependabot-intake.sh"
  ```

- [ ] If provisioning fails, no issue is created, the intake lock is released, and the log names the label problem. A `gh_create_issue` failure log line includes a one-line reason.

  ```yaml
  verify:
    method: codebase
    pattern: "dependencies label unavailable"
    path: ".agents/scripts/pulse-dependabot-intake.sh"
  ```

- [ ] Negative/regression: existing dedup, election, maintainer-hold, authenticity, exact-head scope and concurrency tests pass unchanged.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-dependabot-intake.sh && bash .agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh"
  ```

- [ ] After release, `rg -c "worker issue creation failed" ~/.aidevops/logs/pulse.log` stops growing, and `marcusquinn/cloudron-netbird-app` gains `Dependabot PR #N requires worker resolution` issues. This is observed after deploy, not in this PR.

## Context & Decisions

- Provisioning the label was chosen over dropping it from the request, because intake dedup depends on it.
- Using the shared managed-label library keeps one label catalogue and the existing snapshot-then-create idempotency, rather than an ad-hoc `gh label create`.

## Relevant Files

- `.agents/scripts/pulse-dependabot-intake.sh:55-86,514-612` — election rows and intake route
- `.agents/scripts/managed-label-provisioning-lib.sh:15-76` — label specs and ensure helpers
- `.agents/scripts/shared-gh-wrappers-create.sh:1334-1379` — origin-label ensure and create runner
- `.agents/scripts/tests/test-pulse-dependabot-intake.sh:42-140,153-170` — stubs and creation test

<!-- aidevops:brief-schema=v2 -->

# t19010: fix(tests): test_decision_policy_decide/escalate/races fail on main

## Pre-flight

- [x] Memory recall: `decision policy test failure checkpoint resolver` → 0 hits — no relevant lessons
- [x] Discovery pass: tests added by GH#38155 (`c2683ce9a5`, PR #38166); no open PR touches `pr-checkpoint-decision-resolver.sh` or the dispatch test module
- [x] File refs verified: 3 refs checked, all present at HEAD `1f12709375`
- [x] Tier: `tier:standard` — diagnose a failing fixture in one test module plus at most one helper
- [x] Seeded draft PR decision recorded: skipped — cause not yet known

## Origin

- **Created:** 2026-11-14
- **Created by:** ai-interactive (GH#38358 session)
- **Issue:** GH#38365
- **Conversation context:** While verifying GH#38358, the checkpoint suite showed 3 failures that also occur on unmodified `origin/main`.

## What

`bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh` reports `3 / 208 tests failed` on an unmodified `origin/main` worktree (commit `1f12709375`, macOS, Homebrew coreutils `timeout` present). The failures are `test_decision_policy_decide`, `test_decision_policy_escalate` and `test_decision_policy_races`; `test_decision_policy_trust_and_bounds` (all negative cases) passes. After the fix, all four pass, and the AI brief-owner decision path (GH#38155) is proven to still work in production, not only in the fixture.

## Why

The decision resolver lets Pulse settle reversible `decision` blockers on checkpoint drafts without a maintainer. If the positive path is broken in production, every decision-blocked draft waits for a human. If only the fixture is broken, the suite has no positive coverage for that path. No CI workflow runs this suite (`rg -l test-pr-checkpoint-continuation-helper .github/workflows` finds nothing), so the failure went unnoticed.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Root cause is unknown but confined to one sourced test module and `pr-checkpoint-decision-resolver.sh`. Each positive test returns at its first failed step, so the cause can be found by tracing.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh:9-182`: decision fixtures and the four tests. Fix the fixture if it is the cause.
- `EDIT: .agents/scripts/pr-checkpoint-decision-resolver.sh:108-177`: only if the trace shows a production defect in `_pcc_resolve_decision`.

### Complete Write Surface

- **Callers/readers:** `_pcc_policy_route` (`pr-checkpoint-decision-resolver.sh:6`), reached from the blocked-attention path of `pr-checkpoint-continuation-helper.sh`.
- **Writers/mutation paths:** `gh-write-helper.sh issue edit` (decision record) and `issue comment` (approval or escalation), both stubbed in the fixture.
- **Existing verification/tests:** `test-pr-checkpoint-continuation-helper.sh` sources the dispatch module; the module cannot run alone.
- **Schemas/config:** `repos.json` `checkpoint_policy.auto_resolve_decisions`; N/A because the fixture writes its own registry and no key changes.
- **Generated/deployed mirrors:** deployed copy via `setup.sh` after release.
- **Migrations/backfills:** N/A because nothing persistent changes.
- **Cleanup/rollback paths:** revert the commit; `decision_fixture` in `test-pr-checkpoint-continuation-dispatch.sh` returns to fixed dates.

### Implementation Steps

1. Find the first failing step in `test_decision_policy_decide`: each line ends in `|| return 1`, so add temporary step markers, or run the suite with `bash -x` and filter the `decision-decide` section.
2. Hypothesis to check first (unverified): the fixture uses fixed timestamps (`created_at:"2026-11-13T00:00:00Z"`), and a validator window such as `APPROVAL_TTL_SECONDS = 86400` in `pr_checkpoint_admission.py:49` or a `now` comparison in `pr-checkpoint-revision.py:169,251` rejects them once the date passes. If so, derive fixture timestamps from the current time, or pass an explicit `now`, as other checkpoint tests do.
3. If the trace points at `_pcc_resolve_decision` instead, fix the production defect, then confirm on one live decision-blocked draft that the resolver reaches inference.
4. Rerun the suite until it reports 0 failures.

### Hazards and Compatibility

- **Concurrency/atomicity:** `test_decision_policy_races` checks the two-writer bound with `_pcc_decision_reserve`; keep that check.
- **Migration/rollback:** none.
- **Mixed-version/backward compatibility:** none; test or resolver only.
- **Idempotency/retry:** the resolver must still run inference once per finding (the tests assert one `inferences` line).
- **Partial failure/recovery:** fail-closed escalation on invalid model output must stay unchanged.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh
shellcheck .agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh .agents/scripts/pr-checkpoint-decision-resolver.sh
```

- **Surface mapping:** the parent suite runs all four decision-policy tests through the real inference parser and publication tail; ShellCheck covers both files.

### Files Scope

- `.agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh`
- `.agents/scripts/pr-checkpoint-decision-resolver.sh`

## Acceptance Criteria

- [ ] `test_decision_policy_decide`, `test_decision_policy_escalate`, `test_decision_policy_races` and `test_decision_policy_trust_and_bounds` all pass, and the suite reports 0 failures.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pr-checkpoint-continuation-helper.sh"
  ```

- [ ] The fix does not weaken any trust check: negative cases (hold, owner, outsider, already_landed, policy off) still reject without inference or writes.

  ```yaml
  verify:
    method: codebase
    pattern: "test_decision_policy_trust_and_bounds"
    path: ".agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh"
  ```

## Context & Decisions

- Found during GH#38358 verification: same 3 failures with and without that change (3/208 on main, 3/213 on the branch).
- If the cause is a fixed-date fixture, check sibling checkpoint fixtures for the same pattern and record any others found.

## Relevant Files

- `.agents/scripts/tests/test-pr-checkpoint-continuation-dispatch.sh:9-186` — decision fixtures and tests
- `.agents/scripts/pr-checkpoint-decision-resolver.sh:108-177` — `_pcc_resolve_decision`
- `.agents/scripts/pr_checkpoint_admission.py:49-55` — approval TTL

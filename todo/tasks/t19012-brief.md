<!-- aidevops:brief-schema=v2 -->

# t19012: fix(tests): 7 failing cases in 3 local-only test suites on main

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (t19011 / GH#38388 session)
- **Issue:** GH#38392
- **Conversation context:** While verifying PR #38390, three suites failed on an unmodified `origin/main` worktree at `154ea6f195`. None of them run in CI (`rg -l` over `.github/workflows` finds no reference), so the failures were unnoticed.

## What

All of these pass on `origin/main`, each by fixing whichever side is wrong: the fixture or the production code.

- `test-headless-runtime-helper.sh` (524 cases, 2 fail): `claude worker sandbox receives only validated signing Git configuration`; `Claude bare execution paths use the resolved headless timeout`.
- `test-dispatch-lifecycle-comms.sh` (27 cases, 4 fail, each `got 'unknown'`): `Fix B: partial when issue-named branch exists`; `Fix B: no_work when no PR and no matching branch`; `Fix B: no_work on invalid issue number`; `Fix B: no_work on empty repo slug`. The `partial when open PR exists` case passes.
- `test-pulse-dispatch-worker-launch-comment-metrics.sh` (1 fail): `clean-room authority projected untrusted or raw comment content: outsider`.

## Why

Two of these cover security boundaries (signing Git configuration passed to the worker sandbox; outsider comment content kept out of the clean-room worker prompt). Find out first whether production is wrong or only the fixture. If production leaks outsider content or unvalidated signing configuration, that is a defect, not test drift. The `Fix B` cases cover the dispatch-lifecycle classification that decides whether a worker exit was `partial` or `no_work`; `unknown` there degrades redispatch decisions.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Three independent, deterministic local suites; each failure names its case and the expected value.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/tests/test-headless-runtime-contract-tests.sh` and `.agents/scripts/tests/test-headless-runtime-provider-tests.sh` — the two failing cases, sourced by `test-headless-runtime-helper.sh`.
- `EDIT: .agents/scripts/tests/test-dispatch-lifecycle-comms.sh:329-370` — `Fix B` cases; the production function is `_classify_stale_recovery_crash_type` in `.agents/scripts/pulse-dispatch-dedup-layers.sh:55`. Its stub copy in `.agents/scripts/tests/test-dispatch-dedup-stale-no-worker.sh:194` shows the expected contract.
- `EDIT: .agents/scripts/tests/test-pulse-dispatch-worker-launch-comment-metrics.sh:332-342` — clean-room authority case; it calls `_dlw_prepare_prompt_for_launch`.
- Production files only where the trace shows a defect: the headless sandbox Git-config and timeout paths in `headless-runtime-helper.sh` / `headless-runtime-lib.sh`, `_classify_stale_recovery_crash_type`, and the clean-room comment projection reached from `_dlw_prepare_prompt_for_launch` (`pulse-dispatch-worker-prompt.sh` or `pulse-dispatch-worker-launch.sh`).

### Implementation Steps

1. Run each suite and trace its first failing case to the production function it calls.
2. Use `git log -S` on the asserted string or function to find the commit that diverged test and code.
3. Fix production if it violates the documented contract; otherwise update the fixture to match current intended behaviour and cite the commit.
4. Never weaken a security assertion to make it pass (signing config validation, outsider-content exclusion).

### Verification

```bash
bash .agents/scripts/tests/test-headless-runtime-helper.sh
bash .agents/scripts/tests/test-dispatch-lifecycle-comms.sh
bash .agents/scripts/tests/test-pulse-dispatch-worker-launch-comment-metrics.sh
shellcheck <touched files>
```

### Files Scope

- `.agents/scripts/tests/test-headless-runtime-contract-tests.sh`
- `.agents/scripts/tests/test-headless-runtime-provider-tests.sh`
- `.agents/scripts/tests/test-dispatch-lifecycle-comms.sh`
- `.agents/scripts/tests/test-pulse-dispatch-worker-launch-comment-metrics.sh`
- `.agents/scripts/headless-runtime-helper.sh`
- `.agents/scripts/headless-runtime-lib.sh`
- `.agents/scripts/pulse-dispatch-worker-prompt.sh`
- `.agents/scripts/pulse-dispatch-worker-launch.sh`
- `.agents/scripts/pulse-dispatch-dedup-layers.sh`

## Acceptance Criteria

- [ ] The three suites report 0 failures on the PR head.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dispatch-lifecycle-comms.sh && bash .agents/scripts/tests/test-pulse-dispatch-worker-launch-comment-metrics.sh"
  ```

- [ ] The PR body states, for each of the 7 cases, whether production or the fixture was wrong, with the diverging commit.
- [ ] No security assertion is removed or loosened.

## Context & Decisions

- Out of scope: wiring these suites into CI. File a separate follow-up if the fix shows they are stable and fast enough for a required gate (see `reference/ci-gate-policy.md`).
- Related: t19010 / GH#38365 (another local-only suite failing on main, PR #38378).

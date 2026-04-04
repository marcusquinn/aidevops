<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1441: Unblock patch releases by reducing repo-wide preflight blocker debt

## Origin

- **Created:** 2026-03-11
- **Session:** opencode (interactive planning request)
- **Created by:** OpenCode gpt-5.4
- **Parent task:** none
- **Conversation context:** After the t1440 fix landed, `version-manager.sh release patch` is still blocked by repo-wide preflight failures. The task needs to be tracked in aidevops with a valid task ID, linked GitHub issue, and TODO entry on main so the remaining blocker debt can be cleared and patch releases can ship again.

## What

Identify and fix the repo-wide preflight blockers that still prevent `.agents/scripts/version-manager.sh release patch` from completing after t1440. Reduce the accumulated release-blocking debt across the preflight pipeline so patch releases can ship reliably without manual cleanup or repeated blocker triage.

## Why

- **Restore patch release flow:** the post-t1440 release path is still stuck behind preflight failures, so fixes cannot be shipped promptly
- **Reduce operational drag:** repeated preflight triage slows releases and creates avoidable manual work every time a patch is prepared
- **Improve release confidence:** repo-wide blockers signal quality debt that can surprise maintainers late in the release process
- **Keep the release path trustworthy:** `version-manager.sh release patch` should remain a dependable one-command path, not a fragile sequence of retries and local cleanup

## How (Approach)

1. Reproduce the current failure path for `.agents/scripts/version-manager.sh release patch` and capture which preflight checks are blocking the release after t1440
2. Trace each blocker to its owning script, config, or repo-wide quality gate and group the failures by root cause instead of treating them as one-off symptoms
3. Fix or narrow the blocker conditions so genuine release blockers remain enforced while stale or overly broad debt no longer prevents patch shipping
4. Add or update focused regression coverage for the repaired preflight paths so the same blocker class does not silently reappear
5. Re-run the release-preflight path and confirm the repo can progress through patch release preparation without the previous blocker set

## Acceptance Criteria

- [ ] The current repo-wide preflight blockers preventing patch release are identified and reduced to a concrete, actionable set tied to specific root causes
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/version-manager.sh release patch"
  ```
- [ ] The blocking preflight checks are fixed, narrowed, or otherwise resolved so `version-manager.sh release patch` no longer fails for the post-t1440 blocker debt
  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/version-manager.sh release patch"
  ```
- [ ] Regression coverage or deterministic verification exists for the repaired blocker paths
  ```yaml
  verify:
    method: bash
    run: "git grep -n 'preflight\|release patch\|version-manager' -- .agents/scripts tests"
  ```
- [ ] The release workflow still preserves meaningful preflight protection instead of bypassing all checks to make the command pass
  ```yaml
  verify:
    method: bash
    run: "git grep -n 'preflight\|quality gate\|blocker' -- .agents/scripts prompts tests"
  ```

## Context & Decisions

- Treat this as release-path hardening, not a request to weaken safeguards indiscriminately
- Favor root-cause fixes or scope tightening over adding broad skip flags
- Keep the patch-release workflow aligned with the repo's normal quality expectations
- If some blockers are legitimate unrelated debt, make that debt explicit and bounded so maintainers can prioritize it intentionally

## Relevant Files

- `.agents/scripts/version-manager.sh` — patch release entry point and preflight orchestration
- `.agents/scripts/linters-local.sh` — likely source of repo-wide quality gate failures
- `.agents/scripts/` — helper scripts invoked during release preflight
- `prompts/build.txt` — enforced quality and preflight expectations that may shape blocker behavior
- `tests/` — regression coverage for release and preflight behavior
- `TODO.md` — planning tracker entry that links the issue and dispatchable task

## Dependencies

- **Blocked by:** none
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | reproduce blocker set and map failures to owners |
| Implementation | 1.5h | fix or narrow the release-blocking preflight debt |
| Testing | 45m | rerun release path and regression checks |
| **Total** | **~3h** | |

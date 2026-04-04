<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1440: Fix `aidevops update` failures when Homebrew is unavailable or token refresh returns 500

## Origin

- **Created:** 2026-03-11
- **Session:** opencode (interactive planning request)
- **Created by:** OpenCode gpt-5.4
- **Parent task:** none
- **Conversation context:** Users reported urgent `aidevops update` failures with errors like `timeout: failed to run command 'brew': No such file or directory` and `Error: Token refresh failed: 500`. The task needs a tracked aidevops planning entry and linked GitHub issue so the update path can be fixed quickly.

## What

Investigate and fix the `aidevops update` flow so it does not abort when Homebrew is unavailable in the runtime environment and so upstream token refresh failures return clear, actionable guidance instead of raw provider or shell errors. Cover both the command path that runs the framework update and any helper/auth integration involved in refresh-driven update checks.

## Why

- **Restore trust in self-update:** `aidevops update` is the recovery path users are told to run when tooling drifts or setup breaks
- **Handle common environments:** some installs do not have `brew` on `PATH`, so the update path must detect that and fall back cleanly
- **Reduce support churn:** raw `timeout` and token-refresh errors are hard for users to diagnose without internal context
- **Protect follow-on setup:** failed updates leave agent deployment and project sync steps partially applied or skipped

## How (Approach)

1. Trace the `aidevops update` execution path in `aidevops.sh` and any called setup/update helpers to identify where `brew` is invoked without a presence check and where token refresh or authenticated fetches can fail
2. Add explicit guards and fallback behavior for environments without Homebrew so update checks do not shell out to a missing binary under `timeout`
3. Improve the auth/refresh failure path to catch 5xx refresh responses, surface the likely cause, and print a concrete recovery action instead of a bare upstream error
4. Add focused regression coverage for both failure classes, including a no-Homebrew environment and a simulated token refresh 500 response
5. Verify the repaired update flow still completes normal setup/deploy steps and does not regress existing update behavior

## Acceptance Criteria

- [ ] `aidevops update` no longer emits `timeout: failed to run command 'brew': No such file or directory` when Homebrew is absent
  ```yaml
  verify:
    method: bash
    run: "git grep -n 'command -v brew\|brew not found\|Homebrew' -- aidevops.sh setup.sh setup-modules .agents/scripts"
  ```
- [ ] Token refresh failures during update are caught and reported with actionable guidance, including 5xx refresh responses
  ```yaml
  verify:
    method: bash
    run: "git grep -n 'refresh.*500\|Token refresh\|re-auth\|retry later' -- aidevops.sh .agents/scripts setup.sh"
  ```
- [ ] Regression coverage exists for both the missing-Homebrew and token-refresh failure scenarios
  ```yaml
  verify:
    method: bash
    run: "git grep -n 'brew.*No such file or directory\|Token refresh failed\|refresh failure' -- tests .agents/scripts/tests"
  ```
- [ ] `aidevops update` still completes the normal update/setup path after the hardening changes
  ```yaml
  verify:
    method: bash
    run: "bash tests/test-vm-setup.sh --update"
  ```

## Context & Decisions

- Prefer resilient detection and fallback over assuming Homebrew is always installed
- Keep user-facing error text short and recovery-oriented
- Preserve the existing fast path for healthy installs; this is a hardening fix, not an update redesign
- If the refresh failure originates in a downstream CLI or helper, wrap it at the aidevops boundary with better guidance rather than leaking internal transport detail

## Relevant Files

- `aidevops.sh` — primary `cmd_update()` flow and user-facing update messaging
- `setup.sh` — non-interactive setup path run by `aidevops update`
- `setup-modules/` — package-manager and setup helpers that may invoke Homebrew or auth-sensitive install steps
- `.agents/scripts/aidevops-update-check.sh` — update-related messaging and possible shared upgrade logic
- `tests/test-vm-setup.sh` — existing update-path verification entry point
- `.agents/scripts/tests/` — focused regression coverage for helper-level failure handling

## Dependencies

- **Blocked by:** none
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | trace update and auth/package-manager failure points |
| Implementation | 1h | add guards, fallbacks, and clearer error handling |
| Testing | 30m | focused regressions plus update-path verification |
| **Total** | **~2h** | |

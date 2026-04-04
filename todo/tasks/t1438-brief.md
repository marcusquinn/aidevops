<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t1438: Improve worker stall diagnosis before pulse kills suspect workers

## Origin

- **Created:** 2026-03-11
- **Session:** opencode (interactive `/full-loop` request)
- **Created by:** OpenCode gpt-5.4
- **Parent task:** none
- **Conversation context:** The user asked to upstream an evidence-based worker stall diagnosis improvement so pulse inspects suspect worker transcript tails before killing them, then carry the change through tests, PR, merge, release, and deploy.

## What

Improve the pulse/worker watchdog path so a suspect worker is not killed on a bare "no output" heuristic alone. Before killing for a hang or stall, inspect recent worker transcript or runtime output tails, classify whether the worker still shows meaningful activity, and include the evidence in the kill/retry trail. Add only the minimal helper/runtime support needed to expose that tail evidence and cover it with tests.

## Why

- **Reduce false positives:** some workers look stalled by mtime or log size even while the transcript shows active reasoning, tool work, or recoverable provider issues
- **Better audit trail:** retries and failure comments should explain what pulse saw before it killed the worker
- **Safer automation:** pulse should kill based on evidence, not just elapsed silence
- **Reusable diagnostics:** a small helper for transcript/output tail inspection can support both pulse and standalone watchdog paths

## How (Approach)

1. Inspect the current pulse worker health-check path and the headless runtime session/output artifacts it can already observe
2. Add a minimal helper/runtime surface that can return a recent transcript or output tail for a suspect worker/session without introducing heavy state or broad refactors
3. Update the pulse worker stall logic to consult that evidence before killing, and distinguish "still active", "provider waiting", and "truly stalled" cases as far as the available evidence allows
4. Include the diagnostic tail summary in logs/comments/errors used for requeue or failure transitions
5. Add focused tests for the new helper and the kill-decision path, plus shell/lint verification for modified scripts

## Acceptance Criteria

- [ ] Pulse stall detection inspects recent worker transcript/output evidence before killing a suspect worker
  ```yaml
  verify:
    method: codebase
    pattern: "transcript|output tail|tail evidence|diagnostic tail"
    path: ".agents/scripts/supervisor-archived/pulse.sh"
  ```
- [ ] A minimal helper/runtime path exists to retrieve recent worker session/output tails for diagnosis
  ```yaml
  verify:
    method: bash
    run: "git grep -n 'tail evidence\|recent transcript\|session tail' -- .agents/scripts"
  ```
- [ ] Kill/retry trail includes evidence from the inspected tail, not just timeout text
  ```yaml
  verify:
    method: bash
    run: "git grep -n 'kill_reason=.*evidence\|Retry .*evidence\|diagnostic' -- .agents/scripts/supervisor-archived/pulse.sh .agents/scripts/worker-watchdog.sh"
  ```
- [ ] Focused automated tests cover the new diagnosis behavior
  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-worker-stall-diagnosis.sh"
  ```
- [ ] Modified shell scripts pass ShellCheck
  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/headless-runtime-helper.sh .agents/scripts/supervisor-archived/pulse.sh .agents/scripts/worker-watchdog.sh .agents/scripts/worker-lifecycle-common.sh .agents/scripts/tests/test-worker-stall-diagnosis.sh"
  ```

## Context & Decisions

- Prefer reusing existing headless runtime output/session artifacts over introducing a new transcript store
- Keep the evidence window small (tail only) to avoid noisy logs and privacy leakage
- Favor deterministic heuristics for "still active" vs "truly stalled" over expensive AI classification in the watchdog path
- Extend standalone watchdog support only if it can share the same helper cleanly

## Relevant Files

- `.agents/scripts/supervisor-archived/pulse.sh` — current worker hang detection and kill path
- `.agents/scripts/headless-runtime-helper.sh` — current provider-aware headless runtime and session handling
- `.agents/scripts/worker-watchdog.sh` — standalone worker watchdog that may share the same evidence helper
- `.agents/scripts/worker-lifecycle-common.sh` — shared worker process helpers
- `.agents/scripts/tests/` — place for focused regression coverage

## Dependencies

- **Blocked by:** none
- **Blocks:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | inspect current pulse/runtime/watchdog evidence sources |
| Implementation | 1.5h | helper + pulse/watchdog wiring |
| Testing | 1h | focused regression test + shellcheck |
| **Total** | **~3h** | |

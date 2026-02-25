# t1331: Supervisor circuit breaker — pause on consecutive failures

## Origin

- **Created:** 2026-02-25
- **Session:** OpenCode:ouroboros-comparison
- **Created by:** human (ai-interactive)
- **Conversation context:** Reviewing Ouroboros circuit breaker (3 consecutive empty responses -> pause). User agreed this doesn't happen often in interactive sessions but should exist in the supervisor to prevent burning cycles on repeated failures.

## What

A circuit breaker in the supervisor that:
1. Tracks consecutive failures per task type or globally
2. After N consecutive failures (default: 3), pauses dispatch and notifies the user
3. Notification via GitHub issue tag (e.g., `circuit-breaker`) so it's visible in the issue tracker
4. Manual reset to resume (or auto-reset after configurable cooldown)

The user/system will experience: when the supervisor hits a failure loop (e.g., API down, persistent merge conflicts, model returning garbage), it stops wasting cycles and creates a tagged issue alerting the user.

## Why

The supervisor can currently burn through retries indefinitely on systemic failures (API outages, persistent conflicts, model issues). While t1074 added retry caps per task, there's no global circuit breaker that detects "everything is failing" and pauses. Ouroboros's circuit breaker (3 empty responses -> pause) is a simple, effective pattern.

## How (Approach)

1. Add failure counter to supervisor state DB (`consecutive_failures` column or separate tracking)
2. In `supervisor/dispatch.sh` or `supervisor/pulse.sh`, after a task fails, increment counter
3. On success, reset counter to 0
4. When counter hits threshold (configurable `SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD`, default 3):
   - Pause dispatch (set a `circuit_breaker_tripped` flag in state)
   - Create/update a GitHub issue with `circuit-breaker` label via `issue-sync-helper.sh`
   - Log to supervisor log with details of the failures
5. Resume: `supervisor-helper.sh circuit-breaker reset` or auto-reset after cooldown
6. Pulse Phase 0 checks circuit breaker flag before dispatching

Key files:
- `.agents/scripts/supervisor/pulse.sh` — main pulse loop, check breaker before dispatch
- `.agents/scripts/supervisor/dispatch.sh` — dispatch gating
- `.agents/scripts/supervisor/state.sh` — state tracking
- `.agents/scripts/supervisor/self-heal.sh` — failure recovery (related)
- `.agents/scripts/supervisor/issue-sync.sh` — issue creation for notification

## Acceptance Criteria

- [ ] After 3 consecutive task failures, supervisor pauses dispatch
  ```yaml
  verify:
    method: codebase
    pattern: "circuit.breaker|consecutive_fail"
    path: ".agents/scripts/supervisor/"
  ```
- [ ] A GitHub issue is created/updated with `circuit-breaker` label on trip
  ```yaml
  verify:
    method: codebase
    pattern: "circuit-breaker"
    path: ".agents/scripts/supervisor/"
  ```
- [ ] `supervisor-helper.sh circuit-breaker status` shows current state
- [ ] `supervisor-helper.sh circuit-breaker reset` resumes dispatch
- [ ] Counter resets to 0 on any successful task completion
- [ ] Threshold is configurable via `SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD`
  ```yaml
  verify:
    method: codebase
    pattern: "SUPERVISOR_CIRCUIT_BREAKER_THRESHOLD"
    path: ".agents/scripts/supervisor/"
  ```
- [ ] ShellCheck clean on modified scripts

## Context & Decisions

- Inspired by Ouroboros circuit breaker (3 consecutive empty responses -> pause)
- User specified: "use todo/issue tags to notify" — hence the `circuit-breaker` GitHub label
- Scope is supervisor only — interactive sessions self-correct via user feedback
- Per-task retry limits (t1074, max_retries=3) still apply — circuit breaker is a global safety net
- Auto-reset cooldown is optional (default: manual reset required)
- Chose GitHub issue notification over Telegram/email for simplicity and visibility

## Relevant Files

- `.agents/scripts/supervisor/pulse.sh` — dispatch gating
- `.agents/scripts/supervisor/dispatch.sh` — task dispatch
- `.agents/scripts/supervisor/state.sh` — state DB
- `.agents/scripts/supervisor/self-heal.sh` — related failure recovery
- `.agents/scripts/supervisor-helper.sh` — CLI entry point for new subcommand

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review pulse dispatch flow and state DB |
| Implementation | 1h | Counter tracking, breaker logic, CLI, issue creation |
| Testing | 15m | Simulate consecutive failures |
| **Total** | **~1.5h** | |

# t1311: Supervisor AI-first migration — replace deterministic decision logic with AI pipeline

## Origin

- **Created:** 2026-02-24
- **Session:** claude-code:supervisor-ai-first
- **Created by:** human + ai-interactive
- **Conversation context:** After rewriting the lifecycle engine (ai-lifecycle.sh) to be AI-first (gather→decide→execute), an audit of all 29 supervisor modules (35,741 lines) revealed that 42% (~14,900 lines) is deterministic decision logic — case statements, if/else chains, heuristic trees — that should go through the AI pipeline instead. The lifecycle rewrite (PR #2206) proved the pattern works. This task extends it to the remaining modules.

## What

Systematically migrate all deterministic decision logic in the supervisor from hardcoded shell heuristics to the AI-first pattern: **gather facts → ask AI → execute action**. Each subtask targets one module or logical group, removes the decision logic, and routes it through the existing `ai-lifecycle.sh` / `ai-reason.sh` pipeline. The plumbing (DB, process management, launchd, git ops) and data gathering (ai-context.sh, issue-audit.sh) stay as-is.

Target: reduce the supervisor from ~35,700 lines to ~18,000-20,000 lines while improving decision quality (AI handles edge cases that heuristics miss).

## Why

- 42% of the codebase is deterministic heuristics that can't handle edge cases — they log and wait instead of solving problems
- The AI-first lifecycle engine (PR #2206) proved the pattern: AI decisions are more robust than case statements
- Maintenance burden: every new edge case requires a new shell branch; AI handles novel situations naturally
- The supervisor was passively monitoring for hours without solving issues because deterministic logic couldn't handle unexpected states

## How (Approach)

For each module targeted:
1. Identify all decision functions (case/if-else that decide WHAT to do, not HOW)
2. Extract the decision into a prompt for the AI pipeline (gather state → ask AI → execute)
3. Keep the execution functions (the HOW) as shell — AI decides, shell executes
4. Write tests that verify the AI path produces correct actions for known scenarios
5. Deploy, verify via cron.log and ai-lifecycle decision audit trail
6. Each subtask is one PR, merged independently

Pattern to follow: `ai-lifecycle.sh:gather_task_state()` → `ai-lifecycle.sh:decide_next_action()` → `ai-lifecycle.sh:execute_lifecycle_action()`

## Acceptance Criteria

- [ ] All decision logic migrated to AI pipeline (no case statements deciding lifecycle/dispatch/recovery actions)
  ```yaml
  verify:
    method: bash
    run: "! rg -c 'case.*in$' ~/.aidevops/agents/scripts/supervisor/{pulse,dispatch,deploy,evaluate,sanity-check,self-heal,routine-scheduler}.sh 2>/dev/null | awk -F: '{s+=$2}END{print s+0}' | grep -qv '^0$' || echo 'Some case statements remain — verify they are execution plumbing, not decision logic'"
  ```
- [ ] Dead code removed (lifecycle.sh, git-ops.sh stubs)
  ```yaml
  verify:
    method: bash
    run: "! test -f ~/.aidevops/agents/scripts/supervisor/lifecycle.sh && ! test -f ~/.aidevops/agents/scripts/supervisor/git-ops.sh"
  ```
- [ ] Total line count under 22,000
  ```yaml
  verify:
    method: bash
    run: "wc -l ~/.aidevops/agents/scripts/supervisor/*.sh | tail -1 | awk '{exit ($1 > 22000)}'"
  ```
- [ ] Supervisor pulse runs without errors for 24h after final merge
  ```yaml
  verify:
    method: manual
    prompt: "Check cron.log for errors in the 24h after the last subtask merges"
  ```
- [ ] AI lifecycle decisions logged to ~/.aidevops/logs/ai-lifecycle/ with correct reasoning
  ```yaml
  verify:
    method: bash
    run: "ls ~/.aidevops/logs/ai-lifecycle/decision-*.md 2>/dev/null | wc -l | awk '{exit ($1 < 5)}'"
  ```
- [ ] ShellCheck clean on all modified .sh files
- [ ] Each subtask merged via separate PR with CI green

## Context & Decisions

- The AI-first pattern was proven in PR #2206 (ai-lifecycle.sh rewrite): gather→decide→execute
- Plumbing code (DB, launchd, process mgmt, git ops) stays as shell — only DECISION logic moves to AI
- Data gathering (ai-context.sh, issue-audit.sh, memory-integration.sh) stays as shell — AI needs structured input
- The `_dispatch_ai_worker()` pattern from ai-lifecycle.sh handles complex problems (conflicts, CI failures) by spawning interactive AI workers with full tool access
- Subtasks are ordered by impact (biggest decision modules first) and dependency (evaluate.sh before pulse.sh since pulse calls evaluate)
- Each subtask is independently mergeable — no big-bang migration

## Relevant Files

- `.agents/scripts/supervisor/ai-lifecycle.sh` — The proven AI-first pattern to extend
- `.agents/scripts/supervisor/ai-reason.sh` — AI reasoning engine (builds prompts, calls model)
- `.agents/scripts/supervisor/ai-actions.sh` — Action execution (already AI-first)
- `.agents/scripts/supervisor/ai-context.sh` — State gathering (stays as-is)
- `.agents/scripts/supervisor/pulse.sh:1-4389` — Biggest target: phases 0-4 contain decision logic
- `.agents/scripts/supervisor/dispatch.sh:1-3776` — classify_task_complexity, quality gates
- `.agents/scripts/supervisor/deploy.sh:1-2883` — PR triage, review handling, deliverable verification
- `.agents/scripts/supervisor/evaluate.sh:1-1902` — evaluate_worker heuristic tree (assess-task.sh replacement exists)
- `.agents/scripts/supervisor/sanity-check.sh:1-451` — "what's stuck" decision logic
- `.agents/scripts/supervisor/self-heal.sh:1-392` — failure recovery decisions
- `.agents/scripts/supervisor/routine-scheduler.sh:1-514` — run/skip/defer scheduling decisions

## Dependencies

- **Blocked by:** none (ai-lifecycle.sh pattern already proven and deployed)
- **Blocks:** nothing directly, but improves supervisor reliability for all downstream tasks
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| t1312: Dead code + evaluate.sh | ~3h | Quick wins + biggest heuristic tree |
| t1313: dispatch.sh decisions | ~4h | Model routing, complexity classification |
| t1314: deploy.sh decisions | ~4h | PR triage, review handling |
| t1315: pulse.sh phases 0-4 | ~6h | Biggest module, most interleaved logic |
| t1316: sanity-check + self-heal | ~2h | Small modules, clear decision boundaries |
| t1317: routine-scheduler | ~1h | Small, self-contained |
| t1318: issue-sync + todo-sync decisions | ~3h | Hybrid modules, extract decision parts |
| t1319: cron.sh auto-pickup decisions | ~2h | Dispatch gating, blocked-by checking |
| t1320: state.sh + batch completion | ~2h | State machine edge cases |
| t1321: Integration test + cleanup | ~3h | End-to-end verification, docs |
| **Total** | **~30h** | |

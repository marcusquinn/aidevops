---
mode: subagent
---
# t1340: Opus strategic review phase in supervisor pulse

## Origin

- **Created:** 2026-02-26
- **Session:** opencode:interactive
- **Created by:** marcusquinn (human + ai-interactive)
- **Conversation context:** User asked for queue status, I (opus) provided strategic assessment that the sonnet-tier pulse cannot do — spotted stuck chains, stale worktrees, cancelled-but-open tasks, idle capacity. User observed this meta-reasoning should be automated, not on-demand.

## What

Add a periodic opus-tier strategic review to the supervisor pulse. Every 4 hours, the pulse dispatches an opus session that:

1. Assesses queue health (blocked chains, stale states, cancelled-but-open tasks)
2. Checks resource utilisation (worktrees, open PRs, active workers vs available work)
3. Identifies bottlenecks (what's blocking the most downstream work)
4. Takes corrective action (unblock, clean up, dispatch, file issues)
5. Prioritises strategically (not just "what's next" but "what unblocks the most value")

This is a strategic layer on top of the existing sonnet pulse, which handles mechanical dispatch.

## Why

The sonnet-tier pulse is good at executing defined steps (check PRs, dispatch workers, merge ready PRs) but weak at meta-reasoning: spotting that 55 worktrees is a problem, noticing gaps between cancelled notes and TODO.md state, recognising that 0 workers + 25h of dispatchable work = wasted capacity. Without this, systemic issues accumulate until a human notices.

Cost: ~$1-2/day (6 opus calls, ~10-20K input tokens each). Value: prevents hours of idle capacity and stuck chains.

## How (Approach)

Three components, following existing patterns:

1. **`opus-review-helper.sh`** — cadence control script (follows `session-miner-pulse.sh` pattern). Checks last-run timestamp, enforces 4h minimum interval, manages lock file. Exit 0 = review needed, exit 1 = too soon.

2. **`strategic-review.md`** — AI prompt for the opus review session (follows `pulse.md` pattern). Defines what to check, how to assess, and what actions to take. The prompt is the intelligence; the script is the gate.

3. **Wire into `pulse.md`** — add a new step (after Step 7: Session Miner) that calls the helper script and, if due, dispatches an opus review session.

Key files:
- `.agents/scripts/opus-review-helper.sh` — cadence control
- `.agents/scripts/commands/strategic-review.md` — opus review prompt
- `.agents/scripts/commands/pulse.md` — add Step 8

## Acceptance Criteria

- [ ] `opus-review-helper.sh check` returns exit 0 when no review has run in 4+ hours

  ```yaml
  verify:
    method: bash
    run: "rm -f ~/.aidevops/.agent-workspace/supervisor/.opus-review-last && bash ~/.aidevops/agents/scripts/opus-review-helper.sh check"
  ```

- [ ] `opus-review-helper.sh check` returns exit 1 when review ran recently

  ```yaml
  verify:
    method: bash
    run: "mkdir -p ~/.aidevops/.agent-workspace/supervisor && date +%s > ~/.aidevops/.agent-workspace/supervisor/.opus-review-last && ! bash ~/.aidevops/agents/scripts/opus-review-helper.sh check"
  ```

- [ ] `strategic-review.md` exists with structured review prompt

  ```yaml
  verify:
    method: codebase
    pattern: "strategic review"
    path: ".agents/scripts/commands/strategic-review.md"
  ```

- [ ] `pulse.md` references strategic review as a step

  ```yaml
  verify:
    method: codebase
    pattern: "strategic.review|opus.review"
    path: ".agents/scripts/commands/pulse.md"
  ```

- [ ] ShellCheck clean on opus-review-helper.sh

  ```yaml
  verify:
    method: bash
    run: "shellcheck ~/.aidevops/agents/scripts/opus-review-helper.sh"
  ```

## Context & Decisions

- Chose option 2 (extend pulse) over standalone launchd job — keeps orchestration in one system
- 4h cadence balances cost (~$1-2/day) vs responsiveness
- Follows existing patterns: session-miner-pulse.sh for cadence, pulse.md for AI prompt
- The opus review can take actions (merge PRs, file issues, clean worktrees) — it's not just advisory
- Start with fixed 4h; can tune later based on observed value

## Relevant Files

- `.agents/scripts/commands/pulse.md` — existing pulse prompt to extend
- `.agents/scripts/session-miner-pulse.sh` — cadence control pattern to follow
- `.agents/scripts/circuit-breaker-helper.sh` — state file pattern to follow

## Dependencies

- **Blocked by:** nothing
- **Blocks:** nothing directly, but improves all queue throughput
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | pulse.md, session-miner pattern |
| Implementation | 1.5h | helper script + prompt + pulse.md wiring |
| Testing | 15m | shellcheck, cadence logic |
| **Total** | **~2h** | |

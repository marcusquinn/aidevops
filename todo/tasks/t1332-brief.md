# t1332: Supervisor stuck detection — advisory milestone checks

## Origin

- **Created:** 2026-02-25
- **Session:** OpenCode:ouroboros-comparison
- **Created by:** human (ai-interactive)
- **Conversation context:** Reviewing Ouroboros stuck detection (soft self-check at round 50/100/150 — "Am I stuck?"). User raised concern about quality compromises. Agreed: make it advisory (escalate to user) rather than auto-acting. Tag issues for visibility.

## What

A milestone-based stuck detection system for supervisor-dispatched tasks that:
1. At configurable round/time milestones, evaluates whether a task is making progress
2. If stuck is detected, tags the GitHub issue with `stuck-detection` label and posts a comment
3. Does NOT auto-act (no auto-cancel, no auto-pivot) — advisory only, escalates to user
4. Provides context: what the task has done so far, where it appears stuck, suggested actions

The user/system will experience: long-running supervisor tasks that stall get flagged with a `stuck-detection` tag on their GitHub issue, with a comment explaining what's happening and suggested next steps. The user decides what to do.

## Why

Long-running supervisor tasks can stall silently — spinning on merge conflicts, hitting API issues, or going in circles. Currently the only detection is the hard timeout (which kills the task) or manual inspection. A softer "are you stuck?" check at milestones catches problems earlier without the quality risk of auto-acting.

## How (Approach)

1. Define milestone thresholds in config (`SUPERVISOR_STUCK_CHECK_MINUTES`, default: 30,60,120)
2. In `supervisor/pulse.sh` Phase 4 (worker health), check task duration against milestones
3. At each milestone, use AI reasoning (haiku-tier, cheap) to evaluate task progress:
   - Input: task description, time elapsed, last N log lines, PR status if any
   - Output: `{stuck: boolean, confidence: float, reason: string, suggestions: [string]}`
4. If stuck detected with confidence > 0.7:
   - Add `stuck-detection` label to GitHub issue
   - Post comment with reason and suggestions
   - Log to supervisor log
5. Do NOT pause, cancel, or modify the task — advisory only
6. If task later succeeds, remove the label

Key files:
- `.agents/scripts/supervisor/pulse.sh` — Phase 4 worker health checks
- `.agents/scripts/supervisor/ai-reason.sh` — AI reasoning infrastructure
- `.agents/scripts/supervisor/issue-sync.sh` — issue labeling
- `.agents/scripts/supervisor/evaluate.sh` — task evaluation (related)

## Acceptance Criteria

- [ ] At configurable time milestones, supervisor evaluates task progress
  ```yaml
  verify:
    method: codebase
    pattern: "SUPERVISOR_STUCK_CHECK|stuck.detect|milestone"
    path: ".agents/scripts/supervisor/"
  ```
- [ ] Stuck detection uses AI reasoning (haiku-tier) not heuristics
- [ ] When stuck is detected, GitHub issue gets `stuck-detection` label and explanatory comment
  ```yaml
  verify:
    method: codebase
    pattern: "stuck-detection"
    path: ".agents/scripts/supervisor/"
  ```
- [ ] Detection is advisory only — no auto-cancel, no auto-pivot, no task modification
  ```yaml
  verify:
    method: subagent
    prompt: "Review the stuck detection implementation in .agents/scripts/supervisor/. Verify it NEVER cancels, pauses, or modifies a task — only labels issues and posts comments. Flag any auto-acting behavior."
    files: ".agents/scripts/supervisor/pulse.sh"
  ```
- [ ] Label is removed if task subsequently succeeds
- [ ] Confidence threshold is configurable
- [ ] ShellCheck clean on modified scripts

## Context & Decisions

- Inspired by Ouroboros soft self-check at round 50/100/150
- User raised quality concern: "risk of compromises on quality?" — hence advisory-only, no auto-acting
- User requested: "with a tag" — hence `stuck-detection` GitHub issue label
- Haiku-tier AI for evaluation keeps cost minimal (~$0.001 per check)
- Time-based milestones (not round-based) because our supervisor tracks wall-clock time
- Confidence threshold prevents false positives from triggering noise
- Removing label on success keeps issue tracker clean

## Relevant Files

- `.agents/scripts/supervisor/pulse.sh` — Phase 4, add milestone checks
- `.agents/scripts/supervisor/ai-reason.sh` — AI reasoning calls
- `.agents/scripts/supervisor/issue-sync.sh` — issue labeling
- `.agents/scripts/supervisor/evaluate.sh` — task evaluation patterns

## Dependencies

- **Blocked by:** none
- **Blocks:** nothing
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Review Phase 4 health checks and ai-reason patterns |
| Implementation | 1.5h | Milestone tracking, AI evaluation, issue labeling |
| Testing | 15m | Simulate long-running stuck task |
| **Total** | **~2h** | |

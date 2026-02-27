---
mode: subagent
---

# t1361: Mission skill learning

## Origin

- **Created:** 2026-02-27
- **Session:** claude-code:interactive
- **Created by:** ai-interactive
- **Parent task:** t1357 (Mission system)
- **Conversation context:** Part of the mission system feature set (t1357-t1362). After the mission orchestrator (t1357.3) was completed, this task implements the learning feedback loop — auto-capturing reusable patterns from completed missions.

## What

A skill learning system that runs at mission completion to:

1. Scan mission directories for artifacts (agents, scripts, research docs) created during execution
2. Score artifacts for reusability based on content quality and cross-mission recurrence
3. Suggest promotion of useful artifacts from mission-local to `custom/` (user-permanent) or `draft/` (framework R&D)
4. Store discovered patterns in cross-session memory for future mission planning
5. Track which patterns recur across missions to identify high-value learnings

## Why

Missions create temporary agents and scripts that often solve general problems. Without a learning loop, these artifacts die with the mission — the same problems get re-solved in future missions. This closes the feedback loop: missions produce knowledge, knowledge improves future missions.

Blocked t1357.3 (now complete). Feeds into the broader self-improvement principle in AGENTS.md.

## How (Approach)

**Helper script** (`mission-skill-learning.sh`): Deterministic operations — scan directories, find `.md` agent files and `.sh` scripts, check if similar artifacts exist in other mission dirs, compute recurrence scores. This is the "what to look at" tool.

**Agent doc** (`workflows/mission-skill-learning.md`): Judgment-based guidance — how to evaluate whether an artifact is worth promoting, what makes a good candidate, how to adapt mission-specific content for general use. This is the "how to decide" guide.

**Integration points:**
- `workflows/mission-orchestrator.md` Phase 5 — call skill learning after mission completion
- `templates/mission-template.md` — add Skill Learning section for tracking promotion decisions
- `memory-helper.sh` — store patterns via existing `--auto` flag with `SUCCESS_PATTERN` type

**Key files:**
- `.agents/scripts/mission-skill-learning.sh` — new helper script
- `.agents/workflows/mission-skill-learning.md` — new agent doc
- `.agents/workflows/mission-orchestrator.md:156-264` — Phase 5 + Improvement Feedback sections
- `.agents/templates/mission-template.md:157-167` — Mission Agents table
- `.agents/scripts/memory-helper.sh` — existing, used for storage

## Acceptance Criteria

- [ ] `mission-skill-learning.sh scan <mission-dir>` lists all agent/script artifacts with metadata
  ```yaml
  verify:
    method: bash
    run: "test -x ~/.aidevops/agents/scripts/mission-skill-learning.sh && ~/.aidevops/agents/scripts/mission-skill-learning.sh help | grep -q 'scan'"
  ```
- [ ] `mission-skill-learning.sh score <mission-dir>` outputs promotion recommendations with scores
  ```yaml
  verify:
    method: codebase
    pattern: "cmd_score"
    path: ".agents/scripts/mission-skill-learning.sh"
  ```
- [ ] `mission-skill-learning.sh promote <artifact-path>` copies artifact to draft/ with metadata
  ```yaml
  verify:
    method: codebase
    pattern: "cmd_promote"
    path: ".agents/scripts/mission-skill-learning.sh"
  ```
- [ ] `mission-skill-learning.sh remember <mission-dir>` stores patterns in cross-session memory
  ```yaml
  verify:
    method: codebase
    pattern: "cmd_remember"
    path: ".agents/scripts/mission-skill-learning.sh"
  ```
- [ ] Mission orchestrator Phase 5 references skill learning
  ```yaml
  verify:
    method: codebase
    pattern: "mission-skill-learning"
    path: ".agents/workflows/mission-orchestrator.md"
  ```
- [ ] Mission template includes Skill Learning section
  ```yaml
  verify:
    method: codebase
    pattern: "Skill Learning"
    path: ".agents/templates/mission-template.md"
  ```
- [ ] ShellCheck passes on mission-skill-learning.sh
  ```yaml
  verify:
    method: bash
    run: "shellcheck ~/.aidevops/agents/scripts/mission-skill-learning.sh"
  ```

## Context & Decisions

- **Helper script + agent doc split**: Deterministic operations (file scanning, copying) belong in bash. Judgment calls (is this artifact worth promoting?) belong in agent guidance. This follows the "Intelligence Over Determinism" principle.
- **Recurrence scoring**: Simple heuristic — count how many mission dirs contain similar artifacts (by filename pattern or content similarity). Not ML-based; just frequency counting.
- **Memory integration**: Uses existing `memory-helper.sh store --auto` with `SUCCESS_PATTERN` type. No new memory infrastructure needed.
- **Promotion target**: `draft/` tier (not `custom/` or shared) — promotion to higher tiers requires human review per build-agent.md lifecycle.

## Relevant Files

- `.agents/workflows/mission-orchestrator.md` — integration point at Phase 5
- `.agents/templates/mission-template.md` — template update for Skill Learning section
- `.agents/scripts/memory-helper.sh` — memory storage integration
- `.agents/scripts/memory-graduate-helper.sh` — pattern for graduation/promotion scripts
- `.agents/tools/build-agent/build-agent.md` — agent lifecycle tiers
- `.agents/memory/README.md` — memory system docs

## Dependencies

- **Blocked by:** t1357.3 (mission orchestrator) — completed
- **Blocks:** nothing directly; enables self-improvement loop
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Existing mission + memory system |
| Implementation | 2.5h | Helper script + agent doc + integrations |
| Testing | 30m | ShellCheck + manual verification |
| **Total** | **~3.5h** | |

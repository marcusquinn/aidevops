---
mode: subagent
---
# t1357: Mission System — Autonomous Long-Running Project Orchestration

## Origin

- **Created:** 2026-02-27
- **Session:** Claude Code interactive session
- **Created by:** marcusquinn (human) + ai-interactive
- **Conversation context:** Analysis of Factory.ai Missions (multi-day autonomous coding) led to a broader vision: an autonomous project agent that can research, procure, communicate, build, and self-organise across days/weeks. Not just "multi-day coding" but a full project lifecycle from idea to delivery.

## What

A `/mission` command and mission orchestration agent that takes a high-level goal ("Build a CRM", "Migrate this codebase to TypeScript", "Research and prototype a recommendation engine"), decomposes it into milestones and features, manages resources (accounts, credentials, payments, infrastructure), and drives autonomous execution over hours to days — with two modes:

1. **POC mode** — fast iteration, skip ceremony (briefs, PRs, reviews), commit to main or a single branch
2. **Full mode** — production-quality with standard worktree/PR/review workflows

The mission agent must:
- Analyse budget feasibility and recommend budget scales for various outcome levels
- Self-organise its files and folders as needs are discovered
- Create temporary agents and scripts for the mission, and offer improvements back to aidevops
- Use browser automation for reviewing its own progress and visual research
- Handle email, secrets, and account management for 3rd-party interactions
- Know and respect budgets (time, money, tokens) with model provider options
- Reference aidevops patterns for how to do things it already has working examples for
- Research its own examples when aidevops doesn't have them
- Know user preferences and constraints

### Mission homes:
- `~/.aidevops/missions/{id}/` — homeless missions (no repo yet, POC drafting)
- `todo/missions/{id}/` — missions attached to a project repo

### Mission folder structure:
```
{mission-id}/
├── mission.md          # State file (source of truth)
├── research/           # Gathered research, comparisons, references
├── agents/             # Mission-specific temporary agents
├── scripts/            # Mission-specific temporary scripts
└── assets/             # Screenshots, PDFs, exports, visual research
```

## Why

Current aidevops handles task-level work (`/full-loop`) and supervisor-level dispatch (`/pulse`), but nothing takes a high-level goal and drives it to completion over days. The gap between "I have an idea" and "tasks are in TODO.md ready for dispatch" requires manual decomposition. Missions close this gap and extend beyond code into research, procurement, and infrastructure setup — making aidevops a true autonomous project agent.

Factory.ai's Missions validates the market need but their scope is narrower (coding only). Our vision includes the full project lifecycle.

## How (Approach)

### Phase 1: Foundation (t1357.1-t1357.3)
- Create mission state file template (`templates/mission-template.md`)
- Create `/mission` command (`scripts/commands/mission.md`) with interactive scoping interview
- Create mission orchestrator agent doc with self-organisation guidance

### Phase 2: Execution Modes (t1357.4-t1357.5)
- Add POC mode to `/full-loop` (skip worktrees, skip review, commit to main/branch)
- Integrate mission awareness into pulse supervisor

### Phase 3: Validation & Budget (t1357.6-t1357.7)
- Create milestone validation worker
- Implement budget analysis and recommendation engine (time/money/tokens)

### Dependent Features (t1358-t1362)
- Payment agent for autonomous procurement
- Mission-aware browser QA in milestone validation
- Email agent for 3rd-party communication during missions
- Mission skill learning (auto-capture reusable patterns)
- Mission progress dashboard (CLI + browser)

### Key patterns to follow:
- `scripts/commands/define.md` — interview technique for scoping
- `scripts/commands/pulse.md` — supervisor dispatch pattern
- `scripts/commands/full-loop.md` — worker execution pattern
- `workflows/plans.md` — planning and task decomposition
- `tools/build-agent/build-agent.md` — agent creation lifecycle (draft tier)
- `reference/orchestration.md` — model routing and dispatch

### Key design decisions:
- Mission state in git (markdown), not a database — consistent with "GitHub + TODO.md are the database"
- Orchestrator as pulse extension, not separate daemon
- POC mode is a flag, not a separate system
- Milestones sequential, features within milestones parallelisable
- One orchestrator layer (no recursive sub-orchestrators)
- Missions start homeless in `~/.aidevops/missions/`, migrate to `todo/missions/` when a repo exists
- Mission agents/scripts are temporary (draft tier), with promotion path to aidevops shared

## Acceptance Criteria

- [ ] `/mission "description"` starts an interactive scoping interview
  ```yaml
  verify:
    method: bash
    run: "test -f ~/.aidevops/agents/scripts/commands/mission.md"
  ```
- [ ] Mission state file created in correct location (homeless or repo-attached)
  ```yaml
  verify:
    method: codebase
    pattern: "status: planning"
    path: "templates/mission-template.md"
  ```
- [ ] POC mode commits directly to main (dedicated repo) or single branch (existing repo)
- [ ] Full mode uses standard worktree + PR workflow
- [ ] Budget analysis recommends outcome levels for given budget
- [ ] Mission self-organises its folder (research/, agents/, scripts/, assets/)
- [ ] Pulse supervisor dispatches mission features as workers
- [ ] Milestone validation runs after all features in a milestone complete
- [ ] Mission agents created in draft tier with promotion path
- [ ] Budget tracking (time, money, tokens) with alerts at thresholds

## Context & Decisions

- Factory.ai Missions validated the concept but their scope is coding-only. Our vision extends to full project lifecycle (research, procurement, communication, infrastructure).
- Milestones are sequential with parallel features within — Factory found "serial execution with targeted parallelization has worked better than broad parallelism."
- One orchestrator layer, not recursive — Factory notes recursive management depth as an open question; for our scale, one layer suffices.
- POC mode exists because most missions start as proof-of-concept. The ceremony of briefs/PRs/reviews is valuable for production work but counterproductive for exploration.
- Budget analysis is critical — the mission agent should tell you "for $200 and 40h, you'll get X; for $500 and 80h, you'll get Y" before starting.
- Mission-specific agents are draft-tier by design. They're temporary tools for the mission. If they prove generally useful, they get promoted to custom/ or shared/.

## Relevant Files

- `scripts/commands/define.md` — interview pattern to reuse for mission scoping
- `scripts/commands/pulse.md` — supervisor dispatch to extend with mission awareness
- `scripts/commands/full-loop.md` — worker execution to add POC mode
- `workflows/plans.md` — planning patterns for milestone/feature decomposition
- `templates/brief-template.md` — brief format (used in full mode, skipped in POC)
- `tools/build-agent/build-agent.md` — agent lifecycle tiers (draft for mission agents)
- `reference/orchestration.md` — model routing for mission orchestrator/workers
- `tools/ai-assistants/headless-dispatch.md` — worker dispatch patterns
- `tools/browser/browser-automation.md` — browser QA for milestone validation
- `services/email/` — email capabilities for 3rd-party communication
- `tools/credentials/` — secret management for mission accounts

## Dependencies

- **Blocked by:** None (greenfield)
- **Blocks:** None directly, but enables a new class of autonomous work
- **External:** None for MVP; payment agent (t1358) needs virtual card provider; email agent (t1360) needs SES or similar configured

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 2h | Existing patterns, Factory analysis |
| t1357.1 Mission template | 2h | State file format |
| t1357.2 /mission command | 6h | Interactive scoping + decomposition |
| t1357.3 Mission orchestrator agent | 4h | Self-organisation, guidance |
| t1357.4 POC mode in /full-loop | 2h | Skip ceremony flags |
| t1357.5 Pulse integration | 4h | Mission-aware dispatch |
| t1357.6 Milestone validation | 4h | Integration testing worker |
| t1357.7 Budget analysis engine | 4h | Feasibility + recommendations |
| **Total** | **~28h** | |

| Dependent features | Time | Notes |
|---|---|---|
| t1358 Payment agent | 8h | Virtual cards, budget enforcement |
| t1359 Mission browser QA | 4h | Visual validation in milestones |
| t1360 Email agent for missions | 4h | 3rd-party communication |
| t1361 Mission skill learning | 4h | Auto-capture reusable patterns |
| t1362 Mission progress dashboard | 4h | CLI + browser progress view |
| **Dependent total** | **~24h** | |

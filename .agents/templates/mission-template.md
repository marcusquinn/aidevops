---
id: "m{NNN}"
title: "{Mission Title}"
status: planning  # planning | scoping | active | paused | blocked | validating | completed | abandoned
mode: full  # poc | full
repo: ""  # repo path once attached, empty for homeless missions
created: "{YYYY-MM-DD}"
started: ""
completed: ""

budget:
  time_hours: 0
  money_usd: 0
  token_limit: 0  # 0 = unlimited
  alert_threshold_pct: 80

model_routing:
  orchestrator: opus
  workers: sonnet
  research: haiku
  validation: sonnet

preferences:
  tech_stack: []  # e.g., [typescript, react, postgres]
  deploy_target: ""  # e.g., vercel, coolify, cloudron
  test_framework: ""
  ci_provider: ""
  coding_style: ""  # reference to code-standards or project conventions
---

# {Mission Title}

> {One-line goal statement — what does "done" look like?}

**Created:** {YYYY-MM-DD} by {author} — {app}:{session-id} | **Context:** {1-2 sentences on what prompted this mission}

## Scope

{Desired outcome — not "build X" but what the user/system will experience when complete. Include measurable success criteria.}

**Mode:** POC = commit to main, no ceremony (exploration). Full = worktree + PR, briefs required (production).

**Non-goals:** {Explicitly out of scope — prevents scope creep}

**Constraints:** {Budget limits, timeline, technical constraints, external dependencies}

## Milestones

Milestones are sequential. Features within each milestone are parallelisable. Each feature becomes a TODO entry tagged `mission:{id}` (e.g., `- [ ] t042 Implement user auth #mission:m001 ~3h`).

### Milestone 1: {Name}

**Status:** pending  <!-- pending | active | validating | passed | failed | skipped -->
**Estimate:** ~{X}h | **Validation:** {What must be true for this milestone to pass}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |

<!-- Add milestones following the same pattern. -->

## Resources

| Type | Name | Purpose | Status | Notes |
|------|------|---------|--------|-------|
| credential | {e.g., Stripe} | {Payment processing} | needed / configured / n/a | {gopass path} |
| infra | {e.g., PostgreSQL} | {Primary database} | needed / provisioned / n/a | |
| dependency | {e.g., API approval} | {Blocker description} | pending / resolved | |

## Budget Tracking

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | 0h | 0h | 0h | 0% |
| Money (USD)  | $0 | $0 | $0 | 0% |
| Tokens       | 0  | 0  | 0  | 0% |

**Alert threshold:** 80% — pause and report when any category exceeds this.

### Spend Log

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| | | | | |

<!-- budget-analysis-helper.sh analyse --budget <remaining_usd> --json
     budget-analysis-helper.sh estimate --task "<feature>" --json -->

## Decision Log

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | | | | |

## Mission Agents

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| | | `{mission-dir}/agents/{name}.md` | pending |

<!-- Agents live in the mission's agents/ subfolder. Review for framework promotion after completion. -->

## Research

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| | | | |

<!-- Research artifacts go in {mission-dir}/research/ -->

## Progress Log

| Timestamp | Event | Details |
|-----------|-------|---------|
| | Mission created | |

<!-- Orchestrator appends entries as milestones start, complete, fail, or require re-planning. -->

## Retrospective

_Completed after mission finishes._

**Outcomes:** {What was delivered vs. original goal. Budget accuracy: time / money / tokens budgeted vs. actual.}

**Lessons learned:** {What worked / didn't work / do differently next time}

**Framework improvements:** {Improvements to offer back to aidevops — new agents, scripts, patterns}

### Skill Learning

_Auto-populated by `mission-skill-learner.sh scan` at mission completion._

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| | | | | |

<!-- mission-skill-learner.sh scan {mission-dir}
     mission-skill-learner.sh promote <path> [draft|custom]
     mission-skill-learner.sh patterns --mission {mission_id}
     See: workflows/mission-skill-learning.md -->

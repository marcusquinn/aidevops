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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# {Mission Title}

> {One-line goal statement — what does "done" look like?}

## Origin

- **Created:** {YYYY-MM-DD}
- **Created by:** {author}
- **Session:** {app}:{session-id}
- **Context:** {1-2 sentences on what prompted this mission}

## Scope

**Goal:** {Desired outcome — not "build X" but what the user/system will experience when complete. Include measurable success criteria.}

**Mode:** <!-- poc | full -->

| Mode | Behaviour |
|------|-----------|
| **POC** | Skip ceremony (briefs, PRs, reviews). Commit to main or single branch. Fast iteration, exploration-first. |
| **Full** | Standard worktree + PR workflow. Briefs required. Code review. Production-quality output. |

**Non-goals:** {Explicitly out of scope — prevents scope creep}

**Constraints:** {Budget limits, timeline, technical constraints, external dependencies}

## Milestones

Milestones are sequential; features within each milestone are parallelisable. Each feature becomes a TODO entry tagged `mission:{id}` (Full mode). Example: `- [ ] t042 Implement user auth #mission:m001 ~3h`

### Milestone 1: {Name}

**Status:** pending  <!-- pending | active | validating | passed | failed | skipped -->
**Estimate:** ~{X}h
**Validation:** {What must be true for this milestone to pass}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |
| 1.2 | {Feature description} | {tNNN} | pending | ~{X}h | | |

<!-- Add milestones as needed. Copy the block above. -->

## Resources

<!-- Type: credential | infrastructure | dependency. Credential Notes = gopass path, not the value. -->

| Name | Type | Purpose | Status | Notes |
|------|------|---------|--------|-------|
| {e.g., Stripe} | credential | {Payment processing} | {needed / configured / n/a} | |
| {e.g., PostgreSQL} | infrastructure | {Primary database} | {needed / provisioned / n/a} | |
| {e.g., API approval} | dependency | {api / service / human} | {pending / resolved} | |

## Budget Tracking

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | 0h | 0h | 0h | 0% |
| Money (USD)  | $0 | $0 | $0 | 0% |
| Tokens       | 0  | 0  | 0  | 0% |

<!-- Alert threshold: 80% — pause and report when any category exceeds this.
     Spend log: append rows as spend occurs.
     budget-analysis-helper.sh analyse --budget <remaining_usd> --json
     budget-analysis-helper.sh estimate --task "<feature>" --json -->

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| | | | | |

## Decision Log <!-- Append as they occur. Include trade-offs and constraints. -->

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | | | | |

## Mission Agents <!-- Created on-demand; live in {mission-dir}/agents/. Review for promotion after completion. -->

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| | | `{mission-dir}/agents/{name}.md` | pending |

## Research <!-- Artifacts (PDFs, screenshots, comparisons) go in {mission-dir}/research/ -->

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| | | | |

## Progress Log <!-- Orchestrator appends entries as milestones start, complete, fail, or require re-planning. -->

| Timestamp | Event | Details |
|-----------|-------|---------|
| | Mission created | |

## Retrospective

_Completed after mission finishes._

- **Outcomes:** {What was delivered and how it compares to the original goal}
- **Lessons learned:** {What worked / what didn't / what to do differently}
- **Framework improvements:** {Improvements to offer back to aidevops — new agents, scripts, patterns}

### Budget Accuracy

| Category | Budgeted | Actual | Variance |
|----------|----------|--------|----------|
| Time | | | |
| Money | | | |
| Tokens | | | |

### Skill Learning

<!-- Auto-populated: mission-skill-learner.sh scan {mission-dir}
     Promote: mission-skill-learner.sh promote <path> [draft|custom]
     Patterns: mission-skill-learner.sh patterns --mission {mission_id}
     See: workflows/mission-skill-learning.md -->

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| | | | | |

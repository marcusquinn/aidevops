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

## Origin

- **Created:** {YYYY-MM-DD}
- **Created by:** {author}
- **Session:** {app}:{session-id}
- **Context:** {1-2 sentences on what prompted this mission}

## Scope

### Goal

{Detailed description of the desired outcome. Not "build X" but what the user/system will experience when the mission is complete. Include measurable success criteria where possible.}

### Mode

- **POC**: Skip ceremony (briefs, PRs, reviews). Commit to main (dedicated repo) or single branch (existing repo). Fast iteration, exploration-first.
- **Full**: Standard worktree + PR workflow. Briefs required. Code review. Production-quality output.

**Selected mode:** `{poc|full}`

### Non-Goals

- {Explicitly out of scope — prevents scope creep}
- {Things that look related but are not part of this mission}

### Constraints

- {Budget limits, timeline, technical constraints}
- {External dependencies, API rate limits, service availability}
- {User preferences that constrain choices}

## Milestones

Milestones are sequential. Features within each milestone are parallelisable.

### Milestone 1: {Name}

**Status:** pending  <!-- pending | active | validating | passed | failed | skipped -->
**Estimate:** ~{X}h
**Validation:** {What must be true for this milestone to pass — e.g., "all tests pass", "UI renders correctly", "API responds to all endpoints"}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |
| 1.2 | {Feature description} | {tNNN} | pending | ~{X}h | | |
| 1.3 | {Feature description} | {tNNN} | pending | ~{X}h | | |

### Milestone 2: {Name}

**Status:** pending
**Estimate:** ~{X}h
**Validation:** {Validation criteria}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 2.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |
| 2.2 | {Feature description} | {tNNN} | pending | ~{X}h | | |

<!-- Add more milestones as needed. Template:

### Milestone N: {Name}

**Status:** pending
**Estimate:** ~{X}h
**Validation:** {Validation criteria}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| N.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |

-->

## Resources

### Accounts & Credentials

| Service | Purpose | Status | Secret Key |
|---------|---------|--------|------------|
| {e.g., Stripe} | {Payment processing} | {needed / configured / n/a} | {gopass path, not the value} |

### Infrastructure

| Resource | Purpose | Status | Notes |
|----------|---------|--------|-------|
| {e.g., PostgreSQL} | {Primary database} | {needed / provisioned / n/a} | |

### External Dependencies

| Dependency | Type | Status | Notes |
|------------|------|--------|-------|
| {e.g., API approval} | {api / service / human} | {pending / resolved} | |

## Budget Tracking

### Summary

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | {X}h | 0h | {X}h | 0% |
| Money (USD) | ${X} | $0 | ${X} | 0% |
| Tokens | {X} | 0 | {X} | 0% |

**Alert threshold:** {80}% — pause and report when any category exceeds this.

### Spend Log

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| | | | | |

<!-- Append rows as spend occurs. Budget analysis engine (t1357.7) will automate this. -->

## Decision Log

Decisions made during mission execution. Each entry captures what was decided, why, and what alternatives were considered.

| # | Date | Decision | Rationale | Alternatives Considered |
|---|------|----------|-----------|------------------------|
| 1 | | | | |

<!-- Append decisions as they occur. Include trade-offs and constraints that drove the choice. -->

## Mission Agents

Temporary agents created for this mission. Draft-tier by default — promoted to custom/ or shared/ if generally useful.

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| | | `{mission-dir}/agents/{name}.md` | pending |

<!-- Mission agents are created on-demand as the orchestrator discovers needs.
     They live in the mission's agents/ subfolder.
     After mission completion, review for promotion to the framework. -->

## Research

Key findings gathered during mission execution.

| Topic | Summary | Source | Date |
|-------|---------|--------|------|
| | | | |

<!-- Research artifacts (PDFs, screenshots, comparisons) go in {mission-dir}/research/ -->

## Progress Log

Timestamped log of significant events during mission execution.

| Timestamp | Event | Details |
|-----------|-------|---------|
| | Mission created | |

<!-- The orchestrator appends entries as milestones start, complete, fail, or require re-planning. -->

## Retrospective

_Completed after mission finishes._

### Outcomes

- {What was delivered}
- {How it compares to the original goal}

### Budget Accuracy

| Category | Budgeted | Actual | Variance |
|----------|----------|--------|----------|
| Time | | | |
| Money | | | |
| Tokens | | | |

### Lessons Learned

- {What worked well}
- {What didn't work}
- {What to do differently next time}

### Framework Improvements

- {Improvements to offer back to aidevops — new agents, scripts, patterns discovered}

### Skill Learning

_Auto-populated by `mission-skill-learner.sh scan` at mission completion._

| Artifact | Type | Score | Promoted To | Notes |
|----------|------|-------|-------------|-------|
| | | | | |

<!-- Run: mission-skill-learner.sh scan {mission-dir}
     Promote: mission-skill-learner.sh promote <path> [draft|custom]
     Patterns: mission-skill-learner.sh patterns --mission {mission_id}
     See: workflows/mission-skill-learning.md -->

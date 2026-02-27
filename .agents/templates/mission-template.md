---
id: "m{NNN}"
title: "{Mission Title}"
status: planning  # planning | scoping | active | paused | blocked | validating | completed | abandoned
mode: full  # poc | full
repo: ""  # repo path once attached, empty for homeless missions
plan: "p{NNN}"
created: "{YYYY-MM-DD}"
started: ""
completed: ""

budget:
  time_hours: 0
  money_usd: 0
  token_limit: 0  # 0 = unlimited
  alert_threshold_pct: 80

model_routing:
  orchestrator: opus  # scoping + decomposition
  workers: sonnet  # feature implementation
  research: haiku  # cheapest tier for information gathering
  validation: sonnet  # milestone validation

preferences:
  tech_stack: []  # e.g., [typescript, react, postgres]
  deploy_target: ""  # e.g., vercel, coolify, cloudron
  test_strategy: ""  # e.g., unit+e2e, unit-only, manual
  review_mode: ""  # e.g., self-merge, human-review, ai-review
  coding_style: ""  # reference to code-standards or project conventions
  max_parallel_workers: 2
---

<!--
  Mission state file — the durable entity that groups tasks into a coherent goal.
  Lives at: todo/missions/{mission_id}-mission.md (or project root for single-mission repos)
  Created by: /mission command (Phase 1: Scoping)
  Updated by: mission orchestrator during execution
  Consumed by: pulse supervisor for dispatch, budget engine for tracking

  State in git (markdown), not a database — consistent with "GitHub + TODO.md are the database".
  Milestones sequential, features within milestones parallelisable.
-->

<!--TOON:mission{id,title,status,mode,phase,total_phases,budget_usd,budget_hours,budget_tokens,model_routing,repo,plan,logged,started,completed}:
m{NNN},{Mission Title},{status},{mode},1,4,{budget_usd},{budget_hours},{budget_tokens},{model_routing},{repo},p{NNN},{YYYY-MM-DDTHH:MMZ},,
-->

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

Milestones are sequential. Each must pass validation before the next begins.
Features within a milestone are parallelisable (up to `max_parallel_workers`).

<!--TOON:milestones[0]{id,title,status,features_total,features_done,estimate,started,completed}:
-->

### Milestone 1: {Name}

**Status:** pending  <!-- pending | active | validating | passed | failed | skipped -->
**Estimate:** ~{X}h
**Validation:** {What must be true for this milestone to pass — e.g., "all tests pass", "UI renders correctly", "API responds to all endpoints"}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 1.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |
| 1.2 | {Feature description} | {tNNN} | pending | ~{X}h | | |
| 1.3 | {Feature description} | {tNNN} | pending | ~{X}h | | |

#### Validation Criteria

- [ ] {Specific, testable criterion — e.g., "API returns 200 for /contacts endpoint"}
- [ ] {Integration criterion — e.g., "Frontend renders data from API without errors"}

### Milestone 2: {Name}

**Status:** pending
**Estimate:** ~{X}h
**Validation:** {Validation criteria}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| 2.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |
| 2.2 | {Feature description} | {tNNN} | pending | ~{X}h | | |

#### Validation Criteria

- [ ] {criterion}
- [ ] {criterion}

<!-- Add more milestones as needed (typical range: 3-7). Template:

### Milestone N: {Name}

**Status:** pending
**Estimate:** ~{X}h
**Validation:** {Validation criteria}

| # | Feature | Task ID | Status | Estimate | Worker | PR |
|---|---------|---------|--------|----------|--------|----|
| N.1 | {Feature description} | {tNNN} | pending | ~{X}h | | |

#### Validation Criteria

- [ ] {criterion}

-->

## Resources

External accounts, services, credentials, or purchases needed before or during execution.

<!--TOON:resources[0]{id,type,name,status,needed_by,cost,notes}:
-->

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

Updated by the mission orchestrator after each worker session.

<!--TOON:budget_log[0]{date,phase,task_id,model,tokens_k,cost_usd,hours,notes}:
-->

### Summary

| Category | Budget | Spent | Remaining | % Used |
|----------|--------|-------|-----------|--------|
| Time (hours) | {X}h | 0h | {X}h | 0% |
| Money (USD) | ${X} | $0 | ${X} | 0% |
| Tokens | {X} | 0 | {X} | 0% |

**Alert threshold:** {80}% — pause and report when any category exceeds this.

### Budget Analysis

<!-- Populated during Scoping phase by budget engine (t1357.7) -->

**Feasibility:** {feasible / stretch / over-budget}

| Scenario | Budget | Outcome |
|----------|--------|---------|
| Minimum viable | ${X} / {Y}h | {What you get — core functionality only} |
| Recommended | ${X} / {Y}h | {What you get — full scope with testing} |
| Comprehensive | ${X} / {Y}h | {What you get — full scope + polish + docs} |

### Spend Log

| Date | Category | Amount | Description | Milestone |
|------|----------|--------|-------------|-----------|
| | | | | |

<!-- Append rows as spend occurs. Budget analysis engine (t1357.7) will automate this. -->

## Decision Log

Decisions made during mission execution. Each entry captures what was decided, why, and what alternatives were considered. Prevents re-litigating settled questions.

<!--TOON:decisions[0]{id,date,phase,decision,rationale,alternatives_considered}:
-->

| # | Date | Phase | Decision | Rationale | Alternatives Considered |
|---|------|-------|----------|-----------|------------------------|
| 1 | | | | | |

<!-- Append decisions as they occur. Include trade-offs and constraints that drove the choice. -->

## Mission Agents

Temporary agents created for this mission. Draft-tier by default — promoted to custom/ or shared/ if generally useful after mission completion.

<!--TOON:mission_agents[0]{name,purpose,tier,created,promoted}:
-->

| Agent | Purpose | Path | Promote? |
|-------|---------|------|----------|
| | | `draft/{mission_id}/{name}.md` | pending |

<!-- Mission agents are created on-demand as the orchestrator discovers needs.
     They live in draft/{mission_id}/ within the agents directory.
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

_Completed after mission reaches Completed or Abandoned status._

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
- {Issues filed: GH#NNN}

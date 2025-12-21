# Execution Plans

Complex, multi-session work requiring research, design decisions, and detailed tracking.

Based on [OpenAI's PLANS.md](https://cookbook.openai.com/articles/codex_exec_plans) and [plan.md](https://github.com/Digital-Tvilling/plan.md), with TOON-enhanced parsing.

<!--TOON:meta{version,format,updated}:
1.0,plans-md+toon,2025-12-20T00:00:00Z
-->

## Format

Each plan includes:
- **Status**: Planning / In Progress (Phase X/Y) / Blocked / Completed
- **Time Estimate**: `~2w (ai:1w test:0.5w read:0.5w)`
- **Timestamps**: `logged:`, `started:`, `completed:`
- **Progress**: Timestamped checkboxes with estimates and actuals
- **Decision Log**: Key decisions with rationale
- **Surprises & Discoveries**: Unexpected findings
- **Outcomes & Retrospective**: Results and lessons (when complete)

## Active Plans

### [2025-12-21] aidevops-opencode Plugin

**Status:** Planning
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Architecture:** [.agent/build-mcp/aidevops-plugin.md](../.agent/build-mcp/aidevops-plugin.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p001,aidevops-opencode Plugin,planning,0,4,,opencode|plugin,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,
-->

#### Purpose

Create an optional OpenCode plugin that provides native integration for aidevops. This enables lifecycle hooks (pre-commit quality checks), dynamic agent loading, and cleaner npm-based installation for OpenCode users who want tighter integration.

#### Context from Discussion

**Key decisions:**
- Plugin is **optional enhancement**, not replacement for current multi-tool approach
- aidevops remains compatible with Claude, Cursor, Windsurf, etc.
- Plugin loads agents from `~/.aidevops/agents/` at runtime
- Should detect and complement oh-my-opencode if both installed

**Architecture (from aidevops-plugin.md):**
- Agent loader from `~/.aidevops/agents/`
- MCP registration programmatically
- Pre-commit quality hooks (ShellCheck)
- aidevops CLI exposed as tool

**When to build:**
- When OpenCode becomes dominant enough
- When users request native plugin experience
- When hooks become essential (quality gates)

#### Progress

- [ ] (2025-12-21) Phase 1: Core plugin structure + agent loader ~4h
- [ ] (2025-12-21) Phase 2: MCP registration ~2h
- [ ] (2025-12-21) Phase 3: Quality hooks (pre-commit) ~3h
- [ ] (2025-12-21) Phase 4: oh-my-opencode compatibility ~2h

<!--TOON:milestones[4]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m001,p001,Phase 1: Core plugin structure + agent loader,4h,,2025-12-21T00:00Z,,pending
m002,p001,Phase 2: MCP registration,2h,,2025-12-21T00:00Z,,pending
m003,p001,Phase 3: Quality hooks (pre-commit),3h,,2025-12-21T00:00Z,,pending
m004,p001,Phase 4: oh-my-opencode compatibility,2h,,2025-12-21T00:00Z,,pending
-->

#### Decision Log

- **Decision:** Keep as optional plugin, not replace current approach
  **Rationale:** aidevops must remain multi-tool compatible (Claude, Cursor, etc.)
  **Date:** 2025-12-21

<!--TOON:decisions[1]{id,plan_id,decision,rationale,date,impact}:
d001,p001,Keep as optional plugin,aidevops must remain multi-tool compatible,2025-12-21,None - additive feature
-->

#### Surprises & Discoveries

(To be populated during implementation)

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

<!--TOON:active_plans[1]{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p001,aidevops-opencode Plugin,planning,0,4,,opencode|plugin,2d,1d,0.5d,0.5d,2025-12-21T01:50Z,
-->

## Completed Plans

<!-- Move completed plans here with Outcomes & Retrospective filled in -->

<!--TOON:completed_plans[0]{id,title,owner,tags,est,actual,logged,started,completed,lead_time_days}:
-->

## Archived Plans

<!-- Plans that were abandoned or superseded -->

<!--TOON:archived_plans[0]{id,title,reason,logged,archived}:
-->

---

## Plan Template

Copy this template when creating a new plan:

```markdown
### [YYYY-MM-DD] Plan Title

**Status:** Planning
**Owner:** @username
**Tags:** #tag1 #tag2
**Estimate:** ~Xd (ai:Xd test:Xd read:Xd)
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md)

<!--TOON:plan{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
p00X,Plan Title,planning,0,N,username,tag1|tag2,Xd,Xd,Xd,Xd,YYYY-MM-DDTHH:MMZ,
-->

#### Purpose

Brief description of why this work matters and what problem it solves.

#### Progress

- [ ] (YYYY-MM-DD HH:MMZ) Phase 1: Description ~Xh
- [ ] (YYYY-MM-DD HH:MMZ) Phase 2: Description ~Xh

<!--TOON:milestones[N]{id,plan_id,desc,est,actual,scheduled,completed,status}:
m001,p00X,Phase 1: Description,Xh,,YYYY-MM-DDTHH:MMZ,,pending
-->

#### Decision Log

- **Decision:** What was decided
  **Rationale:** Why this choice was made
  **Date:** YYYY-MM-DD
  **Impact:** Effect on timeline/scope

<!--TOON:decisions[0]{id,plan_id,decision,rationale,date,impact}:
-->

#### Surprises & Discoveries

- **Observation:** What was unexpected
  **Evidence:** How we know this
  **Impact:** How it affects the plan

<!--TOON:discoveries[0]{id,plan_id,observation,evidence,impact,date}:
-->

#### Time Tracking

| Phase | Estimated | Actual | Variance |
|-------|-----------|--------|----------|
| Phase 1 | Xh | - | - |
| Phase 2 | Xh | - | - |
| **Total** | **Xh** | **-** | **-** |

<!--TOON:time_tracking{plan_id,total_est,total_actual,variance_pct}:
p00X,Xh,,
-->
```

### Completing a Plan

When a plan is complete, add this section and move to Completed Plans:

```markdown
#### Outcomes & Retrospective

**What was delivered:**
- Deliverable 1
- Deliverable 2

**What went well:**
- Success 1
- Success 2

**What could improve:**
- Learning 1
- Learning 2

**Time Summary:**
- Estimated: Xd
- Actual: Xd
- Variance: ±X%
- Lead time: X days (logged to completed)

<!--TOON:retrospective{plan_id,delivered,went_well,improve,est,actual,variance_pct,lead_time_days}:
p00X,Deliverable 1; Deliverable 2,Success 1; Success 2,Learning 1; Learning 2,Xd,Xd,X,X
-->
```

---

## Analytics

<!--TOON:analytics{total_plans,active,completed,archived,avg_lead_time_days,avg_variance_pct}:
0,0,0,0,,
-->

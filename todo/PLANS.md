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

<!-- Add active plans here using the template below -->

<!--TOON:active_plans[0]{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
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

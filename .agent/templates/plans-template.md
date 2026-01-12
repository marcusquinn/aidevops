---
mode: subagent
---
# Execution Plans

Complex, multi-session work requiring research, design decisions, and detailed tracking.

Based on [OpenAI's PLANS.md](https://cookbook.openai.com/articles/codex_exec_plans) with TOON-enhanced parsing and [Beads](https://github.com/steveyegge/beads) integration for dependency visualization.

<!--TOON:meta{version,format,updated}:
1.0,plans-md+toon,{{DATE}}
-->

## Format

Each plan includes:
- **Plan ID**: `p001`, `p002`, etc. (for cross-referencing)
- **Status**: Planning / In Progress (Phase X/Y) / Blocked / Completed
- **Time Estimate**: `~2w (ai:1w test:0.5w read:0.5w)`
- **Timestamps**: `logged:`, `started:`, `completed:`
- **Dependencies**: `blocked-by:p001` or `blocks:p003`
- **Linkage (The Pin)**: File:line references for search hit-rate (see below)
- **Progress**: Timestamped checkboxes with estimates and actuals
- **Decision Log**: Key decisions with rationale
- **Surprises & Discoveries**: Unexpected findings
- **Outcomes & Retrospective**: Results and lessons (when complete)

### Linkage (The Pin)

Based on [Loom's spec-as-lookup-table pattern](https://ghuntley.com/ralph/), each plan should include a Linkage section that functions as a lookup table for AI search:

| Concept | Files | Lines | Synonyms |
|---------|-------|-------|----------|
| {concept} | {file path} | {line range} | {related terms} |

**Why this matters:**
- Reduces hallucination by providing explicit anchors
- Improves search hit-rate with synonyms
- Points to exact file hunks for context
- Prevents AI from inventing when it should reference

## Active Plans

<!-- Add active plans here - see Plan Template below -->

<!--TOON:active_plans[0]{id,title,status,phase,total_phases,owner,tags,est,est_ai,est_test,est_read,logged,started}:
-->

## Completed Plans

<!-- Move completed plans here with Outcomes & Retrospective -->

<!--TOON:completed_plans[0]{id,title,owner,tags,est,actual,logged,started,completed,lead_time_days}:
-->

## Archived Plans

<!-- Plans that were abandoned or superseded -->

<!--TOON:archived_plans[0]{id,title,reason,logged,archived}:
-->

---

## Plan Template

```markdown
### p00X: Plan Title

**Status:** Planning
**Owner:** @username
**Tags:** #tag1 #tag2
**Estimate:** ~Xd (ai:Xd test:Xd read:Xd)
**Dependencies:** blocked-by:p001 (if any)
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md)
**Logged:** YYYY-MM-DD

#### Purpose

Brief description of why this work matters.

#### Linkage (The Pin)

| Concept | Files | Lines | Synonyms |
|---------|-------|-------|----------|
| {main concept} | src/path/file.ts | 45-120 | {term1}, {term2} |
| {related concept} | src/path/other.ts | 12-89 | {term3}, {term4} |

#### Progress

- [ ] (YYYY-MM-DD HH:MMZ) Phase 1: Description ~Xh
- [ ] (YYYY-MM-DD HH:MMZ) Phase 2: Description ~Xh

#### Decision Log

(Decisions recorded during implementation)

#### Surprises & Discoveries

(Unexpected findings during implementation)
```

---

## Analytics

<!--TOON:dependencies-->
<!-- Format: child_id|relation|parent_id -->
<!--/TOON:dependencies-->

<!--TOON:analytics{total_plans,active,completed,archived,avg_lead_time_days,avg_variance_pct}:
0,0,0,0,,
-->

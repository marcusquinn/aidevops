---
description: Planning workflow with auto-complexity detection
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Plans Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Save planning discussions as actionable tasks or plans
- **Command**: `/save-todo` - auto-detects complexity
- **Principle**: Don't make user think about where to save

**Files**:

| File | Purpose |
|------|---------|
| `TODO.md` | All tasks (simple + plan references) |
| `todo/PLANS.md` | Complex execution plans with context |
| `todo/tasks/prd-{name}.md` | Product requirement documents |
| `todo/tasks/tasks-{name}.md` | Implementation task lists |

**Workflow**:

```text
Planning Conversation → /save-todo → Auto-detect → Save appropriately
                                                         ↓
Future Session → "Work on X" → Load context → git-workflow.md
```

<!-- AI-CONTEXT-END -->

## Auto-Detection Logic

When `/save-todo` is invoked, analyze the conversation for complexity signals:

| Signal | Indicates | Action |
|--------|-----------|--------|
| Single action item | Simple | TODO.md only |
| < 2 hour estimate | Simple | TODO.md only |
| User says "quick" or "simple" | Simple | TODO.md only |
| Multiple distinct steps | Complex | PLANS.md + TODO.md |
| Research/design needed | Complex | PLANS.md + TODO.md |
| > 2 hour estimate | Complex | PLANS.md + TODO.md |
| Multi-session work | Complex | PLANS.md + TODO.md |
| PRD mentioned or needed | Complex | PLANS.md + TODO.md + PRD |

## Saving Work

### Step 1: Extract from Conversation

- **Title**: Concise task/plan name
- **Description**: What needs to be done
- **Estimate**: Time estimate with breakdown `~Xh (ai:Xh test:Xh read:Xm)`
- **Tags**: Relevant categories (#seo, #security, #feature, etc.)
- **Context**: Key decisions, research findings, constraints discussed

### Step 2: Present with Auto-Detection

**For Simple tasks:**

```text
Saving to TODO.md: "{title}" ~{estimate}

1. Confirm
2. Add more details first
3. Create full plan instead (PLANS.md)
```

**For Complex work:**

```text
This looks like complex work. Creating execution plan.

Title: {title}
Estimate: ~{estimate}
Phases: {count} identified

1. Confirm and create plan
2. Simplify to TODO.md only
3. Add more context first
```

### Step 3: Save Appropriately

#### Simple Save (TODO.md only)

Add to TODO.md Backlog:

```markdown
## Backlog

- [ ] {title} #{tag} ~{estimate} logged:{YYYY-MM-DD}
```

**Format elements** (all optional except description):
- `@owner` - Who should work on this
- `#tag` - Category (seo, security, browser, etc.)
- `~estimate` - Time estimate with breakdown: `~4h (ai:2h test:1h read:30m)`
- `logged:YYYY-MM-DD` - Auto-added when task created

Respond:

```text
Saved: "{title}" to TODO.md (~{estimate})
Start anytime with: "Let's work on {title}"
```

#### Complex Save (PLANS.md + TODO.md)

1. **Create PLANS.md entry**:

```markdown
### [{YYYY-MM-DD}] {Title}

**Status:** Planning
**Estimate:** ~{estimate}
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md) (if needed)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md) (if needed)

#### Purpose

{Why this work matters - from conversation context}

#### Progress

- [ ] ({timestamp}) Phase 1: {description} ~{est}
- [ ] ({timestamp}) Phase 2: {description} ~{est}

#### Context from Discussion

{Key decisions, research findings, constraints from conversation}

#### Decision Log

(To be populated during implementation)

#### Surprises & Discoveries

(To be populated during implementation)
```

2. **Add reference to TODO.md** (bidirectional linking):

```markdown
- [ ] {title} #plan → [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}
```

3. **Optionally create PRD/tasks** if scope warrants (use `/create-prd`, `/generate-tasks`)

Respond:

```text
Saved: "{title}"
- Plan: todo/PLANS.md
- Reference: TODO.md
{- PRD: todo/tasks/prd-{slug}.md (if created)}
{- Tasks: todo/tasks/tasks-{slug}.md (if created)}

Start anytime with: "Let's work on {title}"
```

## Context Preservation

Always capture from the conversation:
- Decisions made and their rationale
- Research findings
- Constraints identified
- Open questions
- Related links or references mentioned

This context goes into the PLANS.md entry under "Context from Discussion" so future sessions have full context.

## Starting Work from Plans

When user says "Let's work on X" or references a task/plan:

### 1. Find Matching Work

```bash
grep -i "{keyword}" TODO.md
grep -i "{keyword}" todo/PLANS.md
ls todo/tasks/*{keyword}* 2>/dev/null
```

### 2. Load Context

If PRD/tasks exist, read them for full context.

### 3. Present with Auto-Selection

```text
Found: "{title}" (~{estimate})

1. Start working (creates branch: {suggested-branch})
2. View full details first
3. Different task

[Enter] or 1 to start
```

### 4. Follow git-workflow.md

After branch creation, follow standard git workflow.

## During Implementation

### Update Progress

After each work session, update `todo/PLANS.md`:

```markdown
#### Progress

- [x] (2025-01-14 10:00Z) Research API endpoints
- [x] (2025-01-14 14:00Z) Create MCP server skeleton
- [ ] (2025-01-15 09:00Z) Implement core tools ← IN PROGRESS
```

### Record Decisions

When making significant choices:

```markdown
#### Decision Log

- **Decision:** Use TypeScript + Bun stack
  **Rationale:** Matches existing MCP patterns, faster builds
  **Date:** 2025-01-14
```

### Note Surprises

When discovering unexpected information:

```markdown
#### Surprises & Discoveries

- **Observation:** Ahrefs rate limits are per-minute, not per-day
  **Evidence:** API docs state 500 requests/minute
  **Impact:** Need to implement request queuing
```

### Check Off Tasks

Update `todo/tasks/tasks-{slug}.md` as work completes:

```markdown
- [x] 1.1 Research API endpoints
- [x] 1.2 Document authentication flow
- [ ] 1.3 Implement auth handler ← CURRENT
```

## Completing a Plan

### 1. Mark Tasks Complete

Ensure all tasks in `todo/tasks/tasks-{slug}.md` are checked.

### 2. Record Time

At commit time, offer time tracking:

```text
Committing: "{title}"
Session duration: 2h 12m
Estimated: ~4h

1. Accept 2h 12m as actual
2. Enter different time
3. Skip time tracking
```

### 3. Update PLANS.md Status

```markdown
**Status:** Completed

#### Outcomes & Retrospective

**What was delivered:**
- {Deliverable 1}
- {Deliverable 2}

**Time Summary:**
- Estimated: 4h
- Actual: 3h 15m
- Variance: -19%
```

### 4. Update TODO.md

Mark the reference task done:

```markdown
## Done

- [x] {title} #plan → [todo/PLANS.md#{slug}] ~4h actual:3h15m completed:2025-01-15
```

### 5. Update CHANGELOG.md

Add entry following `workflows/changelog.md` format.

## PRD and Task Generation

For complex work that needs detailed planning:

### Generate PRD (`/create-prd`)

Ask clarifying questions using numbered options:

```text
To create the PRD, I need to clarify:

1. What is the primary goal?
   A. {option}
   B. {option}

2. Who is the target user?
   A. {option}
   B. {option}

Reply with "1A, 2B" or provide details.
```

Create PRD in `todo/tasks/prd-{slug}.md` using `templates/prd-template.md`.

### Generate Tasks (`/generate-tasks`)

**Phase 1: Parent Tasks**

```text
High-level tasks with estimates:

- [ ] 0.0 Create feature branch ~5m
- [ ] 1.0 {First major task} ~2h
- [ ] 2.0 {Second major task} ~3h

Total: ~5h 5m

Reply "Go" to generate sub-tasks.
```

**Phase 2: Sub-Tasks**

```markdown
- [ ] 0.0 Create feature branch
  - [ ] 0.1 Create and checkout: `git checkout -b feature/{slug}`

- [ ] 1.0 {First major task}
  - [ ] 1.1 {Sub-task}
  - [ ] 1.2 {Sub-task}
```

Create in `todo/tasks/tasks-{slug}.md` using `templates/tasks-template.md`.

## Time Estimation Heuristics

| Task Type | AI Time | Test Time | Read Time |
|-----------|---------|-----------|-----------|
| Simple fix | 15-30m | 10-15m | 5m |
| New function | 30m-1h | 15-30m | 10m |
| New component | 1-2h | 30m-1h | 15m |
| New feature | 2-4h | 1-2h | 30m |
| Architecture change | 4-8h | 2-4h | 1h |
| Research/spike | 1-2h | - | 30m |

## Time Tracking Configuration

Configure per-repo in `.aidevops.json`:

```json
{
  "time_tracking": "prompt",
  "features": ["planning", "time-tracking"]
}
```

| Setting | Behavior |
|---------|----------|
| `true` | Always prompt for time at commit |
| `false` | Never prompt (disable time tracking) |
| `prompt` | Ask once per session, remember preference |

Use `/log-time-spent` command to manually log time anytime.

## Integration with Other Workflows

| Workflow | Integration |
|----------|-------------|
| `git-workflow.md` | Branch names derived from tasks/plans |
| `branch.md` | Task 0.0 creates branch |
| `feature-development.md` | Auto-suggests planning for complex work |
| `preflight.md` | Run before marking plan complete |
| `changelog.md` | Update on plan completion |

## Related

- `feature-development.md` - Feature implementation patterns
- `git-workflow.md` - Branch creation and management
- `branch.md` - Branch naming conventions

## Templates

- `templates/prd-template.md` - PRD structure
- `templates/tasks-template.md` - Task list format
- `templates/todo-template.md` - TODO.md for new repos
- `templates/plans-template.md` - PLANS.md for new repos

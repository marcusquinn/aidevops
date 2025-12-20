---
description: Full planning workflow with PRD and task generation for complex features
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

# Plans Workflow (Full)

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Structured planning for complex, multi-session work
- **When to use**: Features requiring 1+ days, research, or design decisions
- **Quick version**: Use `plans-quick.md` for simpler task recording

**Files**:

| File | Purpose |
|------|---------|
| `TODO.md` | Quick tasks, backlog (root level) |
| `todo/PLANS.md` | Complex execution plans |
| `todo/tasks/prd-{name}.md` | Product requirement documents |
| `todo/tasks/tasks-{name}.md` | Implementation task lists |

**Workflow**:

```text
Planning Conversation → Decision Point → Execute/TODO.md/PLANS.md
                                              ↓
Future Session → "Work on X" → Load context → git-workflow.md
```

<!-- AI-CONTEXT-END -->

## Planning Conversation Completion

After completing planning/research in a conversation, present this choice:

```text
We've planned [summary]. How would you like to proceed?

1. Execute now - Start implementation immediately
2. Add to TODO.md - Record as quick task for later
3. Create execution plan - Add to todo/PLANS.md with full PRD/tasks

Which option? (1-3)
```

### Decision Criteria

| Scope | Time Estimate | Recommendation |
|-------|---------------|----------------|
| Trivial | < 30 mins | Execute now |
| Small | 30 mins - 2 hours | TODO.md |
| Medium | 2 hours - 1 day | TODO.md + notes |
| Large | 1+ days | todo/PLANS.md |
| Complex | Multi-session | todo/PLANS.md + PRD + tasks |

## Option 1: Execute Now

Continue in current conversation:

1. Follow `git-workflow.md` for branch creation
2. Derive branch name from planned work
3. Implement immediately

## Option 2: Add to TODO.md

Add a single-line task to `TODO.md`:

```markdown
## Backlog

- [ ] {task description} @{user} #{tag} ~{estimate}
```

**Format elements** (all optional except description):
- `@owner` - Who should work on this
- `#tag` - Category (seo, security, browser, etc.)
- `~estimate` - Time estimate with breakdown: `~4h (ai:2h test:1h read:30m)`
- `logged:YYYY-MM-DD` - Auto-added when task created
- `YYYY-MM-DD` - Due date or target date

**Time breakdown components:**
- `ai:` - AI implementation time
- `test:` - Human testing/verification time
- `read:` - Time to read/review AI output
- `research:` - Additional research time (added at completion)

Inform user: "Added to TODO.md. Start anytime with: 'Let's work on {task}'"

## Option 3: Create Execution Plan

### Step 1: Create PLANS.md Entry

Add to `todo/PLANS.md` under "Active Plans":

```markdown
### [YYYY-MM-DD] {Plan Title}

**Status:** Planning
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md)

#### Purpose

{Why this work matters - 2-3 sentences}

#### Progress

- [ ] (YYYY-MM-DD HH:MMZ) {First milestone}
- [ ] (YYYY-MM-DD HH:MMZ) {Second milestone}

#### Decision Log

{Empty initially - populated during work}

#### Surprises & Discoveries

{Empty initially - populated during work}
```

### Step 2: Generate PRD (if needed)

Ask clarifying questions using numbered options:

```text
To create the PRD, I need to clarify a few things:

1. What is the primary goal?
   A. {option}
   B. {option}
   C. {option}

2. Who is the target user?
   A. {option}
   B. {option}

3. What is the expected scope?
   A. Minimal viable (1-2 days)
   B. Standard (3-5 days)
   C. Comprehensive (1+ weeks)

Reply with selections like "1A, 2B, 3A" or provide details.
```

Create PRD in `todo/tasks/prd-{slug}.md` using template from `templates/prd-template.md`.

### Step 3: Generate Tasks (if needed)

**Phase 1: Parent Tasks with Time Estimates**

Generate high-level tasks with AI-estimated times:

```text
I've generated the high-level tasks with time estimates:

- [ ] 0.0 Create feature branch ~5m (ai:5m)
- [ ] 1.0 {First major task} ~2h (ai:1.5h test:30m)
- [ ] 2.0 {Second major task} ~3h (ai:2h test:1h)
- [ ] 3.0 {Third major task} ~1h (ai:45m test:15m)

**Total estimate:** ~6h 5m (ai:4h 20m test:1h 45m)

Ready to generate sub-tasks? Reply "Go" to proceed.
```

**Time Estimation Heuristics:**

| Task Type | AI Time | Test Time | Read Time |
|-----------|---------|-----------|-----------|
| Simple fix | 15-30m | 10-15m | 5m |
| New function | 30m-1h | 15-30m | 10m |
| New component | 1-2h | 30m-1h | 15m |
| New feature | 2-4h | 1-2h | 30m |
| Architecture change | 4-8h | 2-4h | 1h |
| Research/spike | 1-2h | - | 30m |

**Phase 2: Sub-Tasks**

After user confirms, break down into actionable sub-tasks:

```markdown
## Tasks

- [ ] 0.0 Create feature branch
  - [ ] 0.1 Create and checkout branch: `git checkout -b feature/{slug}`

- [ ] 1.0 {First major task}
  - [ ] 1.1 {Sub-task}
  - [ ] 1.2 {Sub-task}
```

Create in `todo/tasks/tasks-{slug}.md` using template from `templates/tasks-template.md`.

### Step 4: Inform User

```text
Created execution plan:
- Plan entry: todo/PLANS.md
- PRD: todo/tasks/prd-{slug}.md
- Tasks: todo/tasks/tasks-{slug}.md

Start anytime with: "Let's work on the {plan title} plan"
```

## Starting Work from Plans

When user says "Let's work on X" or references a task/plan:

### 1. Check TODO.md

```bash
grep -i "{keyword}" TODO.md
```

### 2. Check todo/PLANS.md

```bash
grep -i "{keyword}" todo/PLANS.md
```

### 3. Load Context

If PRD/tasks exist, read them:

```bash
ls todo/tasks/*{keyword}* 2>/dev/null
```

### 4. Derive Branch Name

| Source | Branch Name |
|--------|-------------|
| TODO.md task | `{type}/{slugified-description}` |
| PLANS.md entry | `{type}/{plan-slug}` |
| PRD file | `{type}/{prd-feature-name}` |

**Examples**:

| Task/Plan | Generated Branch |
|-----------|------------------|
| `- [ ] Add Ahrefs MCP server #seo` | `feature/add-ahrefs-mcp-server` |
| `### [2025-01-15] User Authentication Overhaul` | `feature/user-authentication-overhaul` |
| `prd-export-csv.md` | `feature/export-csv` |

### 5. Present to User

```text
Found matching work:

**From TODO.md:**
- [ ] Add Ahrefs MCP server integration #seo ~2d

**Suggested branch:** feature/add-ahrefs-mcp-server

1. Create this branch and start
2. Use different branch name
3. View full task/plan details first

Which option? (1-3)
```

### 6. Follow git-workflow.md

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

### 2. Record Time at Commit

At commit time, prompt for time tracking:

```text
Committing changes for: "{task/plan name}"

Session duration: 2h 12m (since branch creation)
Estimated: ~4h (ai:2h test:1.5h read:30m)

1. Accept session duration as actual (2h 12m)
2. Enter different actual time
3. Add research time spent before this session
4. Skip time tracking

Which option? (1-4)
```

### 3. Update PLANS.md Status

Change status and add outcomes with time summary:

```markdown
**Status:** Completed

#### Outcomes & Retrospective

**What was delivered:**
- {Deliverable 1}
- {Deliverable 2}

**What went well:**
- {Success 1}

**What could improve:**
- {Learning 1}

**Time Summary:**
- Estimated: 4h (ai:2h test:1.5h read:30m)
- Actual: 3h 15m (ai:1h 45m test:1h read:30m research:0m)
- Variance: -19%
- Lead time: 3 days (logged to completed)
```

### 3. Move to Completed Section

Move the entire plan entry from "Active Plans" to "Completed Plans".

### 4. Update TODO.md

If there was a corresponding TODO.md entry, mark it done:

```markdown
## Done

- [x] Add Ahrefs MCP server integration #seo 2025-01-15
```

### 5. Update CHANGELOG.md

Add entry following `workflows/changelog.md` format.

## Time Tracking Configuration

Time tracking can be configured per-repo in `.aidevops.json`:

```json
{
  "time_tracking": "prompt",  // "true" | "false" | "prompt"
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
| `git-workflow.md` | Branch names derived from tasks/plans, records `started:` |
| `branch.md` | Task 0.0 creates branch, records start time |
| `feature-development.md` | Auto-suggests `@plans` for complex work |
| `preflight.md` | Run before marking plan complete |
| `changelog.md` | Update on plan completion |
| `release.md` | Time summary for all tasks in release |

## Related Subagents

- `plans-quick.md` - Simplified version for quick task recording
- `feature-development.md` - Feature implementation patterns
- `git-workflow.md` - Branch creation and management
- `branch.md` - Branch naming conventions

## Templates

- `templates/prd-template.md` - PRD structure with time estimates
- `templates/tasks-template.md` - Task list with time tracking
- `templates/todo-template.md` - TODO.md for new repos (via `aidevops init`)
- `templates/plans-template.md` - PLANS.md for new repos (via `aidevops init`)

## TOON Integration

All planning files include TOON blocks in HTML comments for machine parsing:

```html
<!--TOON:tasks[3]{id,desc,est,actual,status}:
t001,Create feature branch,5m,5m,done
t002,Implement core logic,2h,1h45m,done
t003,Write tests,1h,,pending
-->
```

Extract with: `grep -oP '<!--TOON:\K[^>]+(?=-->)' TODO.md`

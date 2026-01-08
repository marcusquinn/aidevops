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
- **Commands**: `/save-todo` (auto-detects), `/ready` (show unblocked), `/sync-beads` (sync to Beads)
- **Principle**: Don't make user think about where to save

**Files**:

| File | Purpose |
|------|---------|
| `TODO.md` | All tasks (simple + plan references) with dependencies |
| `todo/PLANS.md` | Complex execution plans with context |
| `todo/tasks/prd-{name}.md` | Product requirement documents |
| `todo/tasks/tasks-{name}.md` | Implementation task lists |
| `.beads/` | Beads database (synced from TODO.md) |

**Task ID Format**:

| Pattern | Example | Meaning |
|---------|---------|---------|
| `tNNN` | `t001` | Top-level task |
| `tNNN.N` | `t001.1` | Subtask |
| `tNNN.N.N` | `t001.1.1` | Sub-subtask |

**Dependency Syntax**:

| Field | Example | Meaning |
|-------|---------|---------|
| `blocked-by:` | `blocked-by:t001,t002` | Cannot start until these are done |
| `blocks:` | `blocks:t003` | Completing this unblocks these |
| Indentation | 2 spaces | Parent-child relationship |

**Workflow**:

```text
Planning Conversation → /save-todo → Auto-detect → Save appropriately
                                                         ↓
Future Session → "Work on X" → Load context → git-workflow.md
                                                         ↓
                              /ready → Show unblocked tasks
                                                         ↓
                              /sync-beads → Sync to Beads for graph view
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

## Ralph Classification

Tasks can be classified as "Ralph-able" - suitable for autonomous iterative AI loops.

### Ralph Criteria

A task is Ralph-able when it has:

| Criterion | Required | Example |
|-----------|----------|---------|
| **Clear success criteria** | Yes | "All tests pass", "Zero linting errors" |
| **Automated verification** | Yes | Tests, linters, type checkers |
| **Bounded scope** | Yes | Single feature, specific bug fix |
| **No human judgment needed** | Yes | No design decisions, no UX choices |
| **Deterministic outcome** | Preferred | Same input → same expected output |

### Ralph Signals in Conversation

| Signal | Ralph-able? | Why |
|--------|-------------|-----|
| "Make all tests pass" | Yes | Clear, verifiable |
| "Fix linting errors" | Yes | Automated verification |
| "Implement feature X with tests" | Yes | Tests provide verification |
| "Refactor until clean" | Maybe | Needs specific criteria |
| "Make it look better" | No | Subjective, needs human judgment |
| "Design the API" | No | Requires design decisions |
| "Debug production issue" | No | Unpredictable, needs investigation |

### Tagging Ralph-able Tasks

When a task meets Ralph criteria, add the `#ralph` tag:

```markdown
- [ ] t042 Fix all ShellCheck violations in scripts/ #ralph ~2h
- [ ] t043 Implement user auth with tests #ralph #feature ~4h
- [ ] t044 Design new dashboard layout #feature ~3h  (NOT ralph-able)
```

### Ralph Task Requirements

When tagging a task as `#ralph`, ensure it includes:

1. **Completion promise**: What phrase signals success
2. **Verification command**: How to check if done
3. **Max iterations**: Safety limit (default: 20)

**Full format:**

```markdown
- [ ] t042 Fix all ShellCheck violations #ralph ~2h
  ralph-promise: "SHELLCHECK_CLEAN"
  ralph-verify: "shellcheck .agent/scripts/*.sh"
  ralph-max: 10
```

**Shorthand** (for simple cases):

```markdown
- [ ] t042 Fix all ShellCheck violations #ralph(SHELLCHECK_CLEAN) ~2h
```

### Running Ralph Tasks

```bash
# Start a Ralph loop for a tagged task
/ralph-loop "$(grep 't042' TODO.md)" --completion-promise "SHELLCHECK_CLEAN" --max-iterations 10

# Or use the task ID directly
/ralph-task t042
```

### Ralph in PLANS.md

For complex plans, mark Ralph-able phases:

```markdown
#### Progress

- [ ] Phase 1: Research API endpoints ~1h
- [ ] Phase 2: Implement core logic #ralph ~2h
  ralph-promise: "ALL_TESTS_PASS"
  ralph-verify: "npm test"
- [ ] Phase 3: Design UI components ~2h (requires human review)
- [ ] Phase 4: Integration tests #ralph ~1h
  ralph-promise: "INTEGRATION_PASS"
  ralph-verify: "npm run test:integration"
```

### Quality Loop Integration

Built-in Ralph-able workflows:

| Workflow | Command | Promise |
|----------|---------|---------|
| Preflight | `/preflight-loop` | `PREFLIGHT_PASS` |
| PR Review | `/pr-loop` | `PR_APPROVED` |
| Postflight | `/postflight-loop` | `RELEASE_HEALTHY` |

These use `quality-loop-helper.sh` which applies Ralph patterns to quality workflows.

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

- [ ] t{NNN} {title} #{tag} ~{estimate} logged:{YYYY-MM-DD}
```

**Format elements** (all optional except id and description):
- `t{NNN}` - Unique task ID (auto-generated, never reused)
- `@owner` - Who should work on this
- `#tag` - Category (seo, security, browser, etc.)
- `~estimate` - Time estimate with breakdown: `~4h (ai:2h test:1h read:30m)`
- `logged:YYYY-MM-DD` - Auto-added when task created
- `blocked-by:t001,t002` - Dependencies (cannot start until these done)
- `blocks:t003` - What this unblocks when complete

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

## Dependencies and Blocking

### Dependency Syntax

Tasks can declare dependencies using these fields:

```markdown
- [ ] t001 Parent task ~4h
  - [ ] t001.1 Subtask ~2h blocked-by:t002
    - [ ] t001.1.1 Sub-subtask ~1h
  - [ ] t001.2 Another subtask ~1h blocks:t003
```

| Field | Syntax | Meaning |
|-------|--------|---------|
| `blocked-by:` | `blocked-by:t001,t002` | Cannot start until t001 AND t002 are done |
| `blocks:` | `blocks:t003,t004` | Completing this task unblocks t003 and t004 |
| Indentation | 2 spaces per level | Implicit parent-child relationship |

### TOON Dependencies Block

Dependencies are also stored in machine-readable TOON format:

```markdown
<!--TOON:dependencies[N]{from_id,to_id,type}:
t019.2,t019.1,blocked-by
t019.3,t019.2,blocked-by
t020,t019,blocked-by
-->
```

### /ready Command

Show tasks with no open blockers (ready to work on):

```bash
# Invoked via AI assistant
/ready

# Or via script
~/.aidevops/agents/scripts/todo-ready.sh
```

Output:

```text
Ready to work (no blockers):

1. t011 Demote wordpress.md from main agent to subagent ~1h
2. t014 Document RapidFuzz library ~30m
3. t004 Add Ahrefs MCP server integration ~2d

Blocked (waiting on dependencies):

- t019.2 Phase 2: Bi-directional sync (blocked-by: t019.1)
- t020 Git Issues Sync (blocked-by: t019)
```

### Hierarchical Task IDs

Tasks use stable, hierarchical IDs that are never reused:

| Level | Pattern | Example | Use Case |
|-------|---------|---------|----------|
| Top-level | `tNNN` | `t001` | Independent tasks |
| Subtask | `tNNN.N` | `t001.1` | Phases, components |
| Sub-subtask | `tNNN.N.N` | `t001.1.1` | Detailed steps |

**Rules:**
- IDs are assigned sequentially and never reused
- Subtasks inherit parent's ID as prefix
- Maximum depth: 3 levels (t001.1.1)
- IDs are stable across syncs with Beads

## Beads Integration

### Sync with Beads

aidevops Tasks & Plans syncs bi-directionally with [Beads](https://github.com/steveyegge/beads) for graph visualization and analytics.

```bash
# Sync TODO.md → Beads
/sync-beads push

# Sync Beads → TODO.md
/sync-beads pull

# Two-way sync with conflict detection
/sync-beads

# Or via script
~/.aidevops/agents/scripts/beads-sync-helper.sh [push|pull|sync]
```

### Sync Guarantees

| Guarantee | Implementation |
|-----------|----------------|
| No race conditions | Lock file during sync |
| Data integrity | Checksum verification before/after |
| Conflict detection | Warns if both sides changed |
| Audit trail | All syncs logged to `.beads/sync.log` |
| Command-led only | No automatic sync (user controls timing) |

### Beads UIs

After syncing, use Beads ecosystem for visualization:

| UI | Command | Best For |
|----|---------|----------|
| beads_viewer | `bv` | Graph analytics, PageRank, critical path |
| beads-ui | `npx beads-ui start` | Web dashboard, kanban |
| bdui | `bdui` | Quick terminal view |
| perles | `perles` | BQL queries |
| beads.el | `M-x beads-list` | Emacs users |

## Time Tracking Configuration

Configure per-repo in `.aidevops.json`:

```json
{
  "time_tracking": "prompt",
  "features": ["planning", "time-tracking", "beads"]
}
```

| Setting | Behavior |
|---------|----------|
| `true` | Always prompt for time at commit |
| `false` | Never prompt (disable time tracking) |
| `prompt` | Ask once per session, remember preference |

Use `/log-time-spent` command to manually log time anytime.

## Git Branch Strategy for TODO.md Changes

TODO.md changes fall into two categories with different branch strategies:

### Stay on Current Branch (Default)

Most TODO.md changes should stay on the current branch:

| Change Type | Example | Why Stay? |
|-------------|---------|-----------|
| Task discovered during work | "Found we need rate limiting while building auth" | Related context |
| Subtask additions | Adding t019.2.1 while working on t019 | Must stay together |
| Status updates | Moving task to In Progress, marking Done | Part of workflow |
| Dependency updates | Adding `blocked-by:` when discovering blockers | Discovered in context |
| Context notes | Adding notes to tasks you're actively working on | Preserves context |

### Consider Dedicated Branch

When adding **unrelated backlog items** (new ideas, tools to evaluate, future work):

| Condition | Recommendation |
|-----------|----------------|
| No uncommitted changes | Offer branch choice |
| Has uncommitted changes | Stay on current branch (lower friction) |
| Adding 3+ unrelated items | Suggest batching on dedicated branch |

**Prompt pattern** (when adding unrelated backlog items):

```text
Adding {N} backlog items unrelated to `{current-branch}`:
- {item 1}
- {item 2}

1. Add to current branch (quick, may create PR noise)
2. Create `chore/backlog-updates` branch (cleaner history)
3. Add to main directly (TODO.md only, skip PR)
```

### Why Not Always Switch?

A "always switch branches for TODO.md" rule fails the 80% universal applicability test:

- ~45% of todo additions ARE related to current work
- Branch switching adds 2-5 minutes overhead per switch
- Uncommitted changes make switching complex (stash/pop)
- Context is lost when separating related discoveries

**Bottom line**: Use judgment. Related work stays together; unrelated backlog can optionally go to a dedicated branch.

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

---
description: Save current discussion as task or plan (auto-detects complexity)
agent: Build+
mode: subagent
---

Analyze the current conversation and save appropriately based on complexity.

Topic/context: $ARGUMENTS

## Auto-Detection Logic

Analyze the conversation for complexity signals:

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

## Workflow

### Step 1: Analyze Conversation

Extract from the discussion:
- **Title**: Concise task/plan name
- **Description**: What needs to be done
- **Estimate**: Time estimate with breakdown `~Xh (ai:Xh test:Xh read:Xm)`
- **Tags**: Relevant categories (#feature, #bugfix, #enhancement, #docs, etc.)
- **Context**: Key decisions, research findings, constraints discussed

### Step 1b: Evaluate Dispatch Tags

Every task MUST be evaluated for these pipeline tags:

**`#auto-dispatch`** — Add when ALL are true:
- Clear fix/feature description with specific files or patterns
- Bounded scope (~2h or less)
- No user credentials, accounts, or purchases needed
- No design decisions requiring user preference
- Verification is automatable (tests, ShellCheck, browser test)

**`#plan`** — Add when the task needs decomposition into subtasks before implementation (multi-phase, >2h, research/design needed).

**Default to `#auto-dispatch`** — only omit when a specific exclusion applies. This keeps the autonomous pipeline moving. See `workflows/plans.md` "Auto-Dispatch Tagging" for full criteria.

### Step 2: Determine Complexity

Based on signals above, classify as Simple or Complex.

### Step 3: Save with Confirmation

**For Simple tasks** (TODO.md only):

```text
Saving to TODO.md: "{title}" ~{estimate}

1. Confirm
2. Add more details first
3. Create full plan instead (PLANS.md)
```

After confirmation, add to TODO.md Backlog:

```markdown
- [ ] {title} #{tag} #auto-dispatch ~{estimate} logged:{YYYY-MM-DD}
```

(Omit `#auto-dispatch` only if a specific exclusion applies per Step 1b.)

Respond:

```text
Saved: "{title}" to TODO.md (~{estimate})
Start anytime with: "Let's work on {title}"
```

**For Complex work** (PLANS.md + TODO.md):

```text
This looks like complex work. Creating execution plan.

Title: {title}
Estimate: ~{estimate}
Phases: {count} identified

1. Confirm and create plan
2. Simplify to TODO.md only
3. Add more context first
```

After confirmation:

1. Create entry in `todo/PLANS.md`:

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

2. Add reference to TODO.md Backlog:

```markdown
- [ ] {title} #plan → [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}
```

3. Optionally create PRD/tasks files if scope warrants

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

## Examples

**Simple task:**

```text
User: We discussed adding a CSV export button
AI: Saving to TODO.md: "Add CSV export button" ~2h (ai:1.5h test:30m)
    1. Confirm  2. More details  3. Full plan
User: 1
AI: Saved: "Add CSV export button" to TODO.md (~2h)
    Start anytime with: "Let's work on CSV export"
```

**Complex work:**

```text
User: We discussed the authentication overhaul with OAuth, session management, and migration
AI: This looks like complex work. Creating execution plan.
    Title: Authentication Overhaul
    Estimate: ~2w (ai:1w test:0.5w read:0.5w)
    Phases: 4 identified (OAuth, sessions, migration, testing)
    
    1. Confirm and create plan  2. Simplify to TODO.md  3. Add context
User: 1
AI: Saved: "Authentication Overhaul"
    - Plan: todo/PLANS.md
    - Reference: TODO.md
    - PRD: todo/tasks/prd-auth-overhaul.md
    
    Start anytime with: "Let's work on auth overhaul"
```

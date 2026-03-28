---
description: Interactive brief generation — interview the user to surface latent requirements before creating a task brief
agent: Build+
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
---

Interview the user to define a task with full context, then generate a complete brief from `templates/brief-template.md`.

Topic: $ARGUMENTS

## Purpose

Surface implicit requirements before code is written. Most task failures come from unstated assumptions, not implementation bugs. Inspired by [manifest-dev](https://github.com/doodledood/manifest-dev) but lighter — single brief output.

## Workflow

### Step 1: Classify Task Type

Parse `$ARGUMENTS` to classify:

| Type | Signal Words | Default Assumptions |
|------|-------------|---------------------|
| **feature** | add, create, build, implement, new | Minimal footprint, no new deps without discussion |
| **bugfix** | fix, broken, wrong, error, crash, regression | Preserve all other behaviour, add regression test |
| **refactor** | clean, restructure, improve, simplify, extract | No behaviour changes, all tests must still pass |
| **docs** | document, readme, guide, explain, describe | Accurate, concise, follows existing doc patterns |
| **research** | investigate, explore, evaluate, compare, spike | Time-boxed, deliverable is a written recommendation |

Also classify **agent domain** and **model tier** using `reference/task-taxonomy.md`. Include domain tag (e.g., `#seo`, `#content`) in TODO.md entry and as GitHub label. Omit for code tasks (Build+ and coding tier are defaults).

If ambiguous, ask with numbered options (1-5 matching table above), recommend based on description.

Store classification for probe selection in Step 3.

### Step 2: Structured Interview (3-5 questions)

Ask sequentially. Each question: 2-4 concrete options, one recommended. Adapt to task type.

**Core questions (all types):**

- **Q1 Goal** (always first): "In one sentence, what must this task produce?" — offer inferred goal as option 1
- **Q2 Scope boundary**: "What is explicitly NOT in scope?" — offer inferred exclusion, "nothing", or custom
- **Q3 Success criteria**: "How will you know this is done?" — automated tests (recommended for feature/bugfix), manual verification, code review, or custom

**Type-specific questions:** Load from `reference/define-probes/${task_type}.md` and ask 1-2 additional questions.

### Step 3: Latent Criteria Probing

After the interview, run exactly **2 probes** from the task-type probe file:

| Technique | Pattern | When |
|-----------|---------|------|
| **Domain grounding** | "In [domain], the usual pitfall is X. Does that apply?" | Always |
| **Pre-mortem** | "Imagine this ships and fails. What went wrong?" | Features, refactors |
| **Backcasting** | "Working backwards from 'done' — what's the last thing you'd verify?" | Features, research |
| **Outside view** | "Similar tasks in this codebase took N approach. Follow or diverge?" | Refactors, features |
| **Negative space** | "What would make a correct solution unacceptable?" | All types |
| **Assumption surfacing** | "I'm assuming X — correct, or should it be Y?" | All types |

Present probes as concrete questions with options, not open-ended prompts.

### Step 4: Sufficiency Gate

Before generating: "Do I know enough to predict what a code review would reject?" If NO — ask one more targeted question. Maximum total: 7 questions (including probes).

### Step 5: Generate Brief

Read `templates/brief-template.md` and populate from interview answers:

| Interview Data | Brief Section |
|---------------|---------------|
| Task type + goal | **What** |
| Why this matters (from probes) | **Why** |
| Scope + exclusions | **Context & Decisions** (non-goals) |
| Success criteria | **Acceptance Criteria** |
| Domain grounding results | **How (Approach)** |
| Pre-mortem / negative space | **Acceptance Criteria** (negative criteria) |
| Files mentioned | **Relevant Files** |

### Step 6: Present and Confirm

Show the generated brief in full, then offer:

1. Save brief and create task (`/new-task`) (recommended)
2. Edit brief before saving
3. Save brief only (no TODO.md entry)
4. Start over with different answers

If user chooses 1, delegate to `/new-task` with brief content pre-populated.

## Headless Mode

When `--headless` or `$ARGUMENTS` contains ` -- ` (supervisor dispatch), skip interview:

```text
/define --headless -- Add retry logic to API client with exponential backoff
```

1. Auto-classify task type from description
2. Apply default assumptions for that type
3. Generate brief with `Created by: ai-supervisor` in Origin
4. Write to `todo/tasks/{task_id}-brief.md`
5. No confirmation — save immediately

## Example

```text
User: /define Add a dark mode toggle to settings

AI: Classifying: **feature** (adding new capability)

Q1: In one sentence, what must this task produce?
  1. A toggle in settings that switches between light and dark themes (recommended)
  2. Let me describe it differently

User: 1

Q2: What is explicitly NOT in scope?
  1. Per-component theming — just a global light/dark switch (recommended)
  2. Nothing — keep scope open
  3. Let me specify exclusions

User: 1

Q3: How will you know this is done?
  1. Toggle works, theme persists across reloads, no visual regressions (recommended)
  2. Manual verification only
  3. Let me define custom criteria

User: 1

[Pre-mortem] Imagine this ships and a user reports a bug. What's most likely?
  1. Some components don't respect the theme (CSS specificity) (recommended)
  2. Theme resets on navigation
  3. Performance issues from re-rendering

User: 1

[Domain grounding] Dark mode typically needs a CSS variable system or theme
   provider. Does this project already have one?
  1. Yes — extend existing
  2. No — create minimal one
  3. Not sure — I'll check

User: 2

Brief generated for: feature — "Dark mode toggle in settings"
[Shows complete brief]

Next steps:
1. Save brief and create task (/new-task) (recommended)
2. Edit brief before saving
3. Save brief only
4. Start over
```

## Related

- `templates/brief-template.md` — Output template
- `reference/define-probes/` — Per-type probing questions
- `scripts/commands/new-task.md` — Task creation (called after brief generation)
- `workflows/plans.md` — Planning workflow integration

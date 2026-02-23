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

Surface implicit requirements before code is written. Most task failures come from unstated assumptions, not implementation bugs. This command runs a structured interview that:

1. Classifies the task type (feature/bugfix/refactor/docs/research)
2. Asks concrete questions with 2-4 options (one recommended)
3. Probes for latent criteria the user hasn't thought to mention
4. Generates a complete brief ready for `/full-loop` or `/new-task`

Inspired by [manifest-dev](https://github.com/doodledood/manifest-dev) but lighter — single brief output instead of manifest + discovery log + verifier agent.

## Workflow

### Step 1: Classify Task Type

Parse `$ARGUMENTS` to classify the task. Use keyword signals:

| Type | Signal Words | Default Assumptions |
|------|-------------|---------------------|
| **feature** | add, create, build, implement, new | Minimal footprint, no new deps without discussion |
| **bugfix** | fix, broken, wrong, error, crash, regression | Preserve all other behaviour, add regression test |
| **refactor** | clean, restructure, improve, simplify, extract | No behaviour changes, all tests must still pass |
| **docs** | document, readme, guide, explain, describe | Accurate, concise, follows existing doc patterns |
| **research** | investigate, explore, evaluate, compare, spike | Time-boxed, deliverable is a written recommendation |

If ambiguous, ask:

```text
What type of task is this?

1. Feature — adding new capability (recommended based on your description)
2. Bug fix — correcting broken behaviour
3. Refactor — restructuring without behaviour change
4. Docs — documentation or guides
5. Research — investigation with written deliverable
```

Store the classification for probe selection in Step 3.

### Step 2: Structured Interview (3-5 questions)

Ask questions sequentially. Each question offers 2-4 concrete options with one recommended. Adapt based on task type.

**Core questions (all types):**

**Q1: Goal** (always first)

```text
In one sentence, what must this task produce?

1. [Inferred goal from $ARGUMENTS] (recommended)
2. Let me describe it differently
```

**Q2: Scope boundary**

```text
What is explicitly NOT in scope?

1. [Inferred exclusion based on task type] (recommended)
2. Nothing — keep scope open
3. Let me specify exclusions
```

**Q3: Success criteria**

```text
How will you know this is done? Pick the verification approach:

1. Automated tests pass (unit/integration) (recommended for feature/bugfix)
2. Manual verification against specific scenario
3. Code review approval is sufficient
4. Let me define custom criteria
```

**Type-specific questions** — load from `reference/define-probes/{type}.md`:

```bash
probe_file="$HOME/.aidevops/agents/reference/define-probes/${task_type}.md"
```

Read the probe file for the classified type and ask 1-2 additional questions from it.

### Step 3: Latent Criteria Probing

After the structured interview, run exactly **2 probes** selected from the task-type probe file. These use established techniques to surface requirements the user hasn't thought to mention:

| Technique | Question Pattern | When to Use |
|-----------|-----------------|-------------|
| **Domain grounding** | "In [domain], the usual pitfall is X. Does that apply here?" | Always — grounds in real patterns |
| **Pre-mortem** | "Imagine this ships and fails. What went wrong?" | Features, refactors |
| **Backcasting** | "Working backwards from 'done' — what's the last thing you'd verify?" | Features, research |
| **Outside view** | "Similar tasks in this codebase took N approach. Should we follow or diverge?" | Refactors, features |
| **Negative space** | "What would make a correct solution unacceptable?" | All types |
| **Assumption surfacing** | "I'm assuming X — correct, or should it be Y?" | All types |

Present probes as concrete questions with options, not open-ended prompts.

### Step 4: Sufficiency Gate

Before generating the brief, internally verify:

> "Do I know enough to predict what a code review would reject?"

If NO — ask one more targeted question. Maximum total questions: 7 (including probes).

If YES — proceed to brief generation.

### Step 5: Generate Brief

Read `templates/brief-template.md` and populate every section from interview answers:

```bash
# Read the template
cat ~/.aidevops/agents/reference/../templates/brief-template.md
```

Map interview answers to brief sections:

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

```text
Brief generated for: {task_type} — "{goal}"

[Full brief content]

---

Next steps:

1. Save brief and create task (/new-task) (recommended)
2. Edit brief before saving
3. Save brief only (no TODO.md entry)
4. Start over with different answers
```

If the user chooses 1, delegate to `/new-task` with the brief content pre-populated.

## Headless Mode

When `--headless` is passed or `$ARGUMENTS` contains ` -- ` (supervisor dispatch), skip the interview and generate the brief directly from the inline description:

```text
/define --headless -- Add retry logic to API client with exponential backoff
```

In headless mode:
1. Auto-classify task type from description
2. Apply default assumptions for that type
3. Generate brief with `Created by: ai-supervisor` in Origin
4. Write brief to `todo/tasks/{task_id}-brief.md`
5. No confirmation prompt — save immediately

## Examples

```text
User: /define Add a dark mode toggle to settings

AI: Classifying: **feature** (adding new capability)

Q1: In one sentence, what must this task produce?
  1. A toggle in the settings page that switches the app between light and dark themes (recommended)
  2. Let me describe it differently

User: 1

AI: Q2: What is explicitly NOT in scope?
  1. Per-component theming — just a global light/dark switch (recommended)
  2. Nothing — keep scope open
  3. Let me specify exclusions

User: 1

AI: Q3: How will you know this is done?
  1. Toggle works, theme persists across page reloads, no visual regressions (recommended)
  2. Manual verification only
  3. Let me define custom criteria

User: 1

AI: [Pre-mortem probe] Imagine this ships and a user reports a bug. What's most likely?
  1. Some components don't respect the theme (CSS specificity issues) (recommended)
  2. Theme resets on navigation
  3. Performance issues from re-rendering
  4. Something else

User: 1

AI: [Domain grounding] Dark mode implementations typically need a CSS variable system
   or a theme provider. Does this project already have one?
  1. Yes — extend the existing system
  2. No — create a minimal one
  3. Not sure — I'll check

User: 2

AI: Brief generated for: feature — "Dark mode toggle in settings"

[Shows complete brief]

Next steps:
1. Save brief and create task (/new-task) (recommended)
2. Edit brief before saving
3. Save brief only
4. Start over
```

```text
User: /define fix the login timeout on mobile

AI: Classifying: **bugfix** (correcting broken behaviour)

Q1: What's the expected vs actual behaviour?
  1. Users should stay logged in for 24h but get logged out after ~5 minutes on mobile (recommended if this matches)
  2. Let me describe the bug differently

[... continues with bugfix-specific questions ...]
```

## Related

- `templates/brief-template.md` — Output template
- `reference/define-probes/` — Per-type probing questions
- `scripts/commands/new-task.md` — Task creation (called after brief generation)
- `workflows/plans.md` — Planning workflow integration

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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Interview the user, then generate a complete brief from `templates/brief-template.md`. Surface implicit requirements before code is written — most task failures come from unstated assumptions, not implementation bugs.

Topic: $ARGUMENTS

## Workflow

### Step 1: Classify Task Type

| Type | Signal Words | Default Assumptions |
|------|-------------|---------------------|
| **feature** | add, create, build, implement, new | Minimal footprint, no new deps without discussion |
| **bugfix** | fix, broken, wrong, error, crash, regression | Preserve all other behaviour, add regression test |
| **refactor** | clean, restructure, improve, simplify, extract | No behaviour changes, all tests must still pass |
| **docs** | document, readme, guide, explain, describe | Accurate, concise, follows existing doc patterns |
| **research** | investigate, explore, evaluate, compare, spike | Time-boxed, deliverable is a written recommendation |

Also classify **agent domain** and **model tier** using `reference/task-taxonomy.md`. Include domain tag (e.g., `#seo`) in TODO.md entry and as GitHub label. Omit for code tasks.

**Tier classification (cascade dispatch):**

- `tier:simple` — single-file, <100 lines changed, pattern-following. Brief MUST provide verbatim oldString/newString for every edit.
- `tier:standard` — multi-file, structural refactoring, >100 lines, approach depends on reading codebase state.
- `tier:reasoning` — architecture decisions, novel design, complex multi-system trade-offs, security audits.

**Default to `tier:simple` for review feedback and single-file fixes.** Haiku achieves 100% success when briefs provide exact code blocks. Only escalate when the task genuinely requires judgment.

If ambiguous, ask with numbered options (1–5 matching table above), recommend based on description.

### Step 2: Structured Interview (3–5 questions)

Ask sequentially. Each question: 2–4 concrete options, one recommended. Adapt to task type.

**Core questions (all types):**

- **Q1 Goal** (always first): "In one sentence, what must this task produce?" — offer inferred goal as option 1
- **Q2 Scope boundary**: "What is explicitly NOT in scope?" — offer inferred exclusion, "nothing", or custom
- **Q3 Success criteria**: "How will you know this is done?" — automated tests (recommended for feature/bugfix), manual verification, code review, or custom
- **Q4 Implementation anchor** (t1901 — MANDATORY for code tasks): "Which files will need to change, and is there an existing file to model on?" — search the codebase (`git ls-files`, `rg`) to offer concrete file paths. The brief's How section MUST contain at least one file path — briefs without file paths waste worker tokens on exploration.

**Type-specific questions:** Load from `reference/define-probes/${task_type}.md` and ask 1–2 additional questions.

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

Read `templates/brief-template.md` and format using `workflows/brief.md` for the classified tier. Populate from interview answers:

| Interview Data | Brief Section |
|---------------|---------------|
| Task type + goal | **What** |
| Why this matters (from probes) | **Why** |
| Scope + exclusions | **Context & Decisions** (non-goals) |
| Success criteria | **Acceptance Criteria** |
| Domain grounding results | **How (Approach)** |
| Pre-mortem / negative space | **Acceptance Criteria** (negative criteria) |
| Files mentioned | **Relevant Files** |

**Code scaffolding (t1901 — MANDATORY for code tasks):** For each file in Files to Modify, read the reference pattern and draft a code skeleton or diff in the Implementation Steps as fenced code blocks. New files: complete skeleton with imports, function signatures, and inline comments. Edits: exact code block with surrounding context showing insertion point.

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
5. Add `#worker` tag to TODO.md entry
6. No confirmation — save immediately

## Related

- `templates/brief-template.md` — Output template
- `reference/define-probes/` — Per-type probing questions
- `scripts/commands/new-task.md` — Task creation (called after brief generation)
- `workflows/plans.md` — Planning workflow integration

---
description: Save current discussion as task or plan (auto-detects complexity)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Analyze the current conversation, compose a worker-ready brief, and save appropriately based on complexity and execution intent.

Topic/context: $ARGUMENTS

## Core Rule

All TODOs, plans, and issues created by this workflow MUST use `workflows/brief.md` and `templates/brief-template.md` so future workers can execute without the original chat. Saving is not implementation; if the user says `/full-loop`, "work on it now", or equivalent, route to `/full-loop` instead of stopping after capture.

## Intent Routing

| Signal | Action |
|--------|--------|
| `/full-loop`, "work on this now", "fix/implement/do this in this session" | Start `/full-loop $ARGUMENTS`; do not ask whether to begin |
| "background", "worker", "auto-dispatch" | Create a briefed TODO/issue and add `#auto-dispatch` when readiness passes |
| "save", "log", "for later", `/save-todo`, `/aidevops-save-todo` | Save the briefed task, then ask whether to auto-dispatch now/later/not |
| Ambiguous "we need to", "should add", "can you note" | Ask the numbered intent prompt before saving or implementing |

Ambiguous prompt:

```text
Do you want to:
1. Work on this now with /full-loop
2. Save as a TODO for later
3. Save as a TODO and auto-dispatch a background worker
4. Create a GitHub issue
5. Create a GitHub issue and auto-dispatch a worker

Reply 1-5.
```

## Auto-Detection

| Signal | Indicates | Action |
|--------|-----------|--------|
| Single action item / <2h / "quick" | Simple | TODO.md only |
| Multiple steps / >2h / multi-session | Complex | PLANS.md + TODO.md |
| PRD mentioned or needed | Complex | PLANS.md + TODO.md + PRD |

## Step 1: Extract from Conversation

- **Title**: Concise task/plan name
- **Estimate**: `~Xh (ai:Xh test:Xh read:Xm)`
- **Tags**: #feature, #bugfix, #enhancement, #docs, etc.
- **Context**: Decisions, findings, constraints, open questions, links
- **Brief**: Create `todo/tasks/{task_id}-brief.md` from `templates/brief-template.md` using `workflows/brief.md` pre-composition checks.

## Step 1b: Dispatch Tags (MANDATORY)

**`#auto-dispatch`** — Add when ALL true: clear description with specific files/patterns, ≤2h scope, no credentials/purchases needed, no user-preference design decisions, automatable verification. **Default to `#auto-dispatch`** — omit only when a specific exclusion applies. Full criteria: `workflows/plans.md` "Auto-Dispatch Tagging". Canonical blocker labels: `reference/dispatch-blockers.md`.

**`#plan`** — Add when decomposition needed before implementation (multi-phase, >2h, research/design).

**Model tier / agent domain tags** — classify via `reference/task-taxonomy.md`. Omit for standard code tasks.

## Step 2: Save

**Simple** → create `todo/tasks/{task_id}-brief.md`, add to TODO.md Backlog, and confirm:

```markdown
- [ ] t{NNN} {title} #{tag} #auto-dispatch ~{estimate} logged:{YYYY-MM-DD}
```

**Complex** → confirm, then:

1. Create entry in `todo/PLANS.md`:

```markdown
### [{YYYY-MM-DD}] {Title}

**Status:** Planning
**Estimate:** ~{estimate}
**PRD:** [todo/tasks/prd-{slug}.md](tasks/prd-{slug}.md) (if needed)
**Tasks:** [todo/tasks/tasks-{slug}.md](tasks/tasks-{slug}.md) (if needed)

#### Purpose

{Why this work matters}

#### Progress

- [ ] ({timestamp}) Phase 1: {description} ~{est}
- [ ] ({timestamp}) Phase 2: {description} ~{est}

#### Context from Discussion

{Key decisions, research findings, constraints, open questions}

#### Decision Log

(To be populated during implementation)

#### Surprises & Discoveries

(To be populated during implementation)
```

2. Create `todo/tasks/{task_id}-brief.md` with implementation context or a plan handoff.
3. Add reference to TODO.md Backlog:

```markdown
- [ ] {title} #plan → [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}
```

4. Optionally create PRD/tasks files if scope warrants.

## Confirmation Prompts

**Simple:**

```text
Saving to TODO.md: "{title}" ~{estimate} | Creating brief: todo/tasks/{task_id}-brief.md
1. Confirm  2. Add more details  3. Create full plan instead
```

**Complex:**

```text
This looks like complex work. Creating execution plan and brief.
Title: {title} | Estimate: ~{estimate} | Phases: {count}
1. Confirm and create plan + brief  2. Simplify to TODO.md + brief  3. Add context
```

After saving, do not respond with only "Start anytime". Use:

```text
Saved as {task_id}: "{title}" with brief {brief_path}.

Auto-dispatch a worker?
1. Yes, start now in the background
2. Later
3. No, keep it manual
```

If the task was created with explicit background/worker intent and dispatch readiness passes, report the queued/dispatch action instead of asking.

## Example

```text
User: We discussed the authentication overhaul with OAuth, session management, and migration
AI:   Complex work. Title: Authentication Overhaul | ~2w | 4 phases | Creating brief: todo/tasks/{task_id}-brief.md
      1. Confirm and create plan + brief  2. Simplify to TODO.md + brief  3. Add context
User: 1
AI:   Saved as t123: "Authentication Overhaul" with brief todo/tasks/t123-brief.md
      - Plan: todo/PLANS.md
      - Reference: TODO.md
      - PRD: todo/tasks/prd-auth-overhaul.md
      Auto-dispatch a worker?
      1. Yes, start now in the background
      2. Later
      3. No, keep it manual
```

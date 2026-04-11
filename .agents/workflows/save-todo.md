---
description: Save current discussion as task or plan (auto-detects complexity)
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Analyze the current conversation and save appropriately based on complexity.

Topic/context: $ARGUMENTS

## Auto-Detection

| Signal | Indicates | Action |
|--------|-----------|--------|
| Single action / <2h / "quick" | Simple | TODO.md only |
| Multiple steps / >2h / multi-session | Complex | PLANS.md + TODO.md |
| PRD mentioned or needed | Complex | PLANS.md + TODO.md + PRD |

## Step 1: Extract from Conversation

- **Title**: Concise task/plan name
- **Estimate**: `~Xh (ai:Xh test:Xh read:Xm)`
- **Tags**: #feature, #bugfix, #enhancement, #docs, etc.
- **Context**: Decisions, findings, constraints, open questions, links
- **`#auto-dispatch`** — Add when ALL true: clear description with specific files/patterns, ≤2h scope, no credentials/purchases needed, no user-preference design decisions, automatable verification. Default to `#auto-dispatch` — omit only when a specific exclusion applies. Full criteria: `workflows/plans.md` "Auto-Dispatch Tagging".
- **`#plan`** — Add when decomposition needed before implementation (multi-phase, >2h, research/design).
- **Model tier / agent domain tags** — classify via `reference/task-taxonomy.md`. Omit for standard code tasks.

## Step 2: Save

**Simple** → add to TODO.md Backlog and confirm:

```markdown
- [ ] {title} #{tag} #auto-dispatch ~{estimate} logged:{YYYY-MM-DD}
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

2. Add reference to TODO.md Backlog:

```markdown
- [ ] {title} #plan → [todo/PLANS.md#{slug}] ~{estimate} logged:{YYYY-MM-DD}
```

3. Optionally create PRD/tasks files if scope warrants.

## Confirmation

**Simple:** `Saving to TODO.md: "{title}" ~{estimate} — 1. Confirm  2. Add details  3. Create full plan`

**Complex:** `Complex work. Title: {title} | ~{estimate} | {count} phases — 1. Confirm  2. Simplify  3. Add context`

After saving: `Saved: "{title}" — Start anytime with: "Let's work on {title}"`

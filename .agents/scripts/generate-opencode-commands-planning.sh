#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Generate OpenCode Commands -- Planning & Tasks
# =============================================================================
# PRD generation, task list management, and planning command definitions
# for OpenCode.
#
# Usage: source "${SCRIPT_DIR}/generate-opencode-commands-planning.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, color vars)
#   - create_command() from the orchestrator
#   - AGENT_BUILD constant from the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OPENCODE_CMDS_PLANNING_LOADED:-}" ]] && return 0
_OPENCODE_CMDS_PLANNING_LOADED=1

# --- Planning & Task Commands ---
# Split into PRD generation and task list management sub-groups.

define_prd_commands() {
	create_command "create-prd" \
		"Generate a Product Requirements Document for a feature" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/plans.md and follow its PRD generation instructions.

Feature to document: $ARGUMENTS

**Workflow:**
1. Ask 3-5 clarifying questions with numbered options (1A, 2B format)
2. Generate PRD using template from ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/templates/prd-template.md
3. Save to todo/tasks/prd-{feature-slug}.md
4. Offer to generate tasks with /generate-tasks

**Question format:**
```
1. What is the primary goal?
   A. Option 1
   B. Option 2
   C. Option 3

2. Who is the target user?
   A. Option 1
   B. Option 2
```

User can reply with "1A, 2B" or provide details.
BODY

	create_command "generate-tasks" \
		"Generate implementation tasks from a PRD" \
		"$AGENT_BUILD" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/workflows/plans.md and follow its task generation instructions.

PRD or feature: $ARGUMENTS

**Workflow:**
1. If PRD file provided, read it
2. If feature name provided, look for todo/tasks/prd-{name}.md
3. Generate parent tasks (Phase 1) and present to user
4. Wait for user to say "Go"
5. Generate sub-tasks (Phase 2)
6. Save to todo/tasks/tasks-{feature-slug}.md

**Task 0.0 is always:** Create feature branch

**Output format:**
```markdown
- [ ] 0.0 Create feature branch
  - [ ] 0.1 Create and checkout: `git checkout -b feature/{slug}`

- [ ] 1.0 First major task
  - [ ] 1.1 Sub-task
  - [ ] 1.2 Sub-task
```

Mark tasks complete by changing `- [ ]` to `- [x]` as work progresses.
BODY

	return 0
}

cmd_list_todo() {
	create_command "list-todo" \
		"List tasks and plans with sorting, filtering, and grouping" \
		"$AGENT_BUILD" "" <<'BODY'
Read TODO.md and todo/PLANS.md and display tasks based on arguments.

Arguments: $ARGUMENTS

**Default (no args):** Show all pending tasks grouped by status (In Progress -> Backlog)

**Sorting options:**
- `--priority` or `-p` - Sort by priority (high -> medium -> low)
- `--estimate` or `-e` - Sort by time estimate (shortest first)
- `--date` or `-d` - Sort by logged date (newest first)
- `--alpha` or `-a` - Sort alphabetically

**Filtering options:**
- `--tag <tag>` or `-t <tag>` - Filter by tag (#seo, #security, etc.)
- `--owner <name>` or `-o <name>` - Filter by assignee (@marcus, etc.)
- `--status <status>` - Filter by status (pending, in-progress, done, plan)
- `--estimate <range>` - Filter by estimate (e.g., "<2h", ">1d", "1h-4h")

**Grouping options:**
- `--group-by tag` or `-g tag` - Group by tag
- `--group-by owner` or `-g owner` - Group by assignee
- `--group-by status` or `-g status` - Group by status (default)
- `--group-by estimate` or `-g estimate` - Group by size (small/medium/large)

**Display options:**
- `--plans` - Include full plan details from PLANS.md
- `--done` - Include completed tasks
- `--all` - Show everything (pending + done + plans)
- `--compact` - One-line per task (no details)
- `--limit <n>` - Limit results

**Examples:**

```bash
/list-todo                           # All pending, grouped by status
/list-todo --priority                # Sorted by priority
/list-todo -t seo                    # Only #seo tasks
/list-todo -o marcus -e              # Marcus's tasks, shortest first
/list-todo -g tag                    # Grouped by tag
/list-todo --estimate "<2h"          # Quick wins under 2 hours
/list-todo --plans                   # Include plan details
/list-todo --all --compact           # Everything, one line each
```

**Output format:**

```markdown
## In Progress (2)

| Task | Est | Tags | Owner |
|------|-----|------|-------|
| Add CSV export | ~2h | #feature | @marcus |
| Fix login bug | ~1h | #bugfix | - |

## Backlog (5)

| Task | Est | Tags | Owner |
|------|-----|------|-------|
| Ahrefs MCP integration | ~2d | #seo | - |
| ...

## Plans (1)

### aidevops-opencode Plugin
**Status:** Planning (Phase 0/4)
**Estimate:** ~2d
**Next:** Phase 1: Core plugin structure
```

After displaying, offer:
1. Work on a specific task (enter number or name)
2. Filter/sort differently
3. Done browsing
BODY

	return 0
}

cmd_save_todo() {
	create_command "save-todo" \
		"Save current discussion as task or plan (auto-detects complexity)" \
		"$AGENT_BUILD" "" <<'BODY'
Analyze the current conversation and save appropriately based on complexity.

Topic/context: $ARGUMENTS

## Auto-Detection

| Signal | Action |
|--------|--------|
| Single action, < 2h | TODO.md only |
| User says "quick/simple" | TODO.md only |
| Multiple steps, > 2h | PLANS.md + TODO.md |
| Research/design needed | PLANS.md + TODO.md |

## Workflow

1. Extract from conversation: title, description, estimate, tags, context
2. Classify as Simple or Complex
3. Save with confirmation (numbered options for override)

**Simple (TODO.md):**
```
Saving to TODO.md: "{title}" ~{estimate}
1. Confirm
2. Add more details
3. Create full plan instead
```

**Complex (PLANS.md + TODO.md):**
```
Creating execution plan: "{title}" ~{estimate}
1. Confirm and create
2. Simplify to TODO.md only
3. Add more context first
```

After save, respond:
```
Saved: "{title}" to {location} (~{estimate})
Start anytime with: "Let's work on {title}"
```

## Context Preservation

Capture from conversation:
- Decisions and rationale
- Research findings
- Constraints identified
- Open questions
- Related links

This goes into PLANS.md "Context from Discussion" section.
BODY

	return 0
}

cmd_plan_status() {
	create_command "plan-status" \
		"Show active plans and TODO.md status" \
		"$AGENT_BUILD" "" <<'BODY'
Read TODO.md and todo/PLANS.md to show current planning status.

Filter: $ARGUMENTS (optional: "in-progress", "backlog", plan name)

**Output format:**

## TODO.md

### In Progress
- [ ] Task 1 @owner #tag ~estimate

### Backlog (top 5)
- [ ] Task 2 #tag
- [ ] Task 3 #tag

## Active Plans (todo/PLANS.md)

### Plan Name
**Status:** In Progress (Phase 2/4)
**Progress:** 3/7 tasks complete
**Next:** Task description

---

Offer options:
1. Work on a specific task/plan
2. Add new task to TODO.md
3. Create new execution plan
BODY

	return 0
}

define_task_list_commands() {
	cmd_list_todo
	cmd_save_todo
	cmd_plan_status
	return 0
}

define_planning_commands() {
	define_prd_commands
	define_task_list_commands
	return 0
}

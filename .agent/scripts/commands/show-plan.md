---
description: Show detailed information about a specific plan from PLANS.md
agent: Build+
mode: subagent
---

Display detailed plan information including purpose, progress, decisions, and related tasks.

Arguments: $ARGUMENTS

## Quick Output (Default)

Run the helper script for instant output:

```bash
~/.aidevops/agents/scripts/show-plan-helper.sh $ARGUMENTS
```

Display the output directly to the user. The script handles all formatting.

## Fallback (Script Unavailable)

If the script fails or is unavailable:

1. Read `todo/PLANS.md`
2. Find the matching plan section by fuzzy title match or plan ID
3. Extract and format all sections (Purpose, Progress, Decisions, etc.)
4. Find related tasks in `TODO.md`

## Arguments

**Plan identifier (required unless --list or --current):**
- Plan name (fuzzy match): `opencode`, `destructive`, `beads`
- Plan ID: `p001`, `p002`, etc.

**Options:**
- `--current` - Show plan related to current git branch
- `--list` - List all active plans briefly
- `--json` - Output as JSON

## Examples

```bash
/show-plan opencode              # Show aidevops-opencode Plugin plan
/show-plan p001                  # Show plan by ID
/show-plan --current             # Show plan for current branch
/show-plan --list                # List all plans
/show-plan "destructive"         # Fuzzy match "Destructive Command Hooks"
/show-plan beads                 # Show Beads Integration plan
```

## Output Format

The script outputs formatted Markdown:

```markdown
# Plan Title

**Status:** Planning (Phase 0/4)
**Estimate:** ~2d (ai:1d test:0.5d read:0.5d)
**Progress:** Phase 0 of 4

## Purpose

Brief description of why this work matters and what problem it solves.

## Progress

- [ ] Phase 1: Description ~Xh
- [ ] Phase 2: Description ~Xh
- [x] Phase 3: Description ~Xh (completed)

## Context

Key decisions, research findings, constraints from conversation.

## Decisions

- **Decision:** What was decided
  **Rationale:** Why this choice was made
  **Date:** YYYY-MM-DD

## Discoveries

- **Observation:** What was unexpected
  **Evidence:** How we know this
  **Impact:** How it affects the plan

## Related Tasks

- t008: aidevops-opencode Plugin
- t009: Claude Code Destructive Command Hooks

---

**Options:**
1. Start working on this plan
2. View another plan
3. Back to task list (`/list-todo`)
```

## After Display

Wait for user input:

1. **"1"** - Begin working on the plan
   - Run pre-edit check
   - Create/switch to appropriate branch
   - Mark first pending phase as in-progress

2. **"2"** - View another plan
   - Prompt for plan name, then run `/show-plan <name>`

3. **"3"** - Return to task list
   - Run `/list-todo`

## Starting Work on a Plan

When user chooses to start:

1. **Check branch status:**

   ```bash
   ~/.aidevops/agents/scripts/pre-edit-check.sh
   ```

2. **Create branch if needed:**
   - Derive branch name from plan title
   - Use worktree: `wt switch -c feature/<plan-slug>`

3. **Update plan status:**
   - Change `**Status:** Planning` to `**Status:** In Progress (Phase 1/N)`
   - Add `started:` timestamp to first phase

4. **Show next steps:**
   - Display first phase description
   - List any blockers or dependencies

## Related Commands

- `/list-todo` - List all tasks and plans
- `/save-todo` - Save current discussion as task/plan
- `/ready` - Show tasks with no blockers

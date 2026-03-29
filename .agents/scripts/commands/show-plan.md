---
description: Show detailed information about a specific plan from PLANS.md
agent: Build+
mode: subagent
---

Display detailed plan information including purpose, progress, decisions, and related tasks.

Arguments: $ARGUMENTS

## Quick Output (Default)

```bash
~/.aidevops/agents/scripts/show-plan-helper.sh $ARGUMENTS
```

Display the output directly to the user. The script handles all formatting.

## Fallback (Script Unavailable)

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

Script outputs formatted Markdown with: Status, Estimate, Progress phases (checkboxes), Purpose, Context, Decisions (with Rationale + Date), Discoveries (with Evidence + Impact), Related Tasks, and numbered options (1=start, 2=view another, 3=back to `/list-todo`).

## After Display

Wait for user input:

1. **"1"** - Begin working on the plan → run pre-edit check, create/switch branch, mark first phase in-progress
2. **"2"** - View another plan → prompt for name, run `/show-plan <name>`
3. **"3"** - Return to task list → run `/list-todo`

## Starting Work on a Plan

1. Run `~/.aidevops/agents/scripts/pre-edit-check.sh`
2. Create branch if needed: `wt switch -c feature/<plan-slug>`
3. Update plan status: `**Status:** Planning` → `**Status:** In Progress (Phase 1/N)`, add `started:` timestamp
4. Display first phase description and any blockers

## Related Commands

- `/list-todo` - List all tasks and plans
- `/save-todo` - Save current discussion as task/plan
- `/ready` - Show tasks with no blockers

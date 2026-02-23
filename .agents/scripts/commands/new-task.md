---
description: Allocate a new task ID with collision-safe distributed locking
agent: Build+
mode: subagent
---

Allocate a new task ID using `claim-task-id.sh` (distributed lock via GitHub/GitLab issue creation) and add it to TODO.md.

For complex tasks where requirements are unclear, use `/define` first — it runs an interactive interview to surface latent criteria before creating the brief.

Topic/context: $ARGUMENTS

## Workflow

### Step 1: Determine Task Title

Extract the task title from the user's request. If no title is provided, ask for one.

### Step 2: Allocate Task ID

Run the wrapper function or script directly:

```bash
# Via planning-commit-helper.sh wrapper (preferred)
output=$(~/.aidevops/agents/scripts/planning-commit-helper.sh next-id --title "Task title here")

# Or directly via claim-task-id.sh
output=$(~/.aidevops/agents/scripts/claim-task-id.sh --title "Task title here" --repo-path "$(git rev-parse --show-toplevel)")
```

### Step 3: Parse Output

The output contains machine-readable variables:

```text
TASK_ID=tNNN
TASK_REF=GH#NNN
TASK_ISSUE_URL=https://github.com/user/repo/issues/NNN
TASK_OFFLINE=false
```

Parse these:

```bash
task_id=$(echo "$output" | grep '^TASK_ID=' | cut -d= -f2)
task_ref=$(echo "$output" | grep '^TASK_REF=' | cut -d= -f2)
task_offline=$(echo "$output" | grep '^TASK_OFFLINE=' | cut -d= -f2)
```

### Step 4: Present to User

Show the allocated ID and ask for task metadata:

```text
Allocated: {task_id} (ref:{task_ref})

Task: "{title}"
ID: {task_id}
Ref: ref:{task_ref}

Options:
1. Add to TODO.md with brief (recommended)
2. Customize estimate, tags, and dependencies
3. Just show the ID (don't add to TODO.md)
```

### Step 5: Create Task Brief (MANDATORY)

**Every task MUST have a brief file** at `todo/tasks/{task_id}-brief.md`. This is non-negotiable. A task without a brief is undevelopable.

Use `templates/brief-template.md` as the base. Populate from conversation context:

```markdown
# {task_id}: {Title}

## Origin
- **Created:** {ISO date}
- **Session:** {app}:{session-id} (detect from runtime — e.g., opencode:session-xyz, claude-code:abc123)
- **Created by:** {author} (human | ai-supervisor | ai-interactive)
- **Parent task:** {parent_id} (if subtask — include link to parent brief)
- **Conversation context:** {1-2 sentence summary of what was discussed}

## What
{Clear deliverable description — not "implement X" but what it must produce}

## Why
{Problem, user need, business value, or dependency requiring this}

## How (Approach)
{Technical approach, key files, patterns to follow}
{Reference existing code: `path/to/file.ts:45`}

## Acceptance Criteria
- [ ] {Specific, testable criterion}
- [ ] Tests pass
- [ ] Lint clean

## Context & Decisions
{Key decisions, constraints, things ruled out}

## Relevant Files
- `path/to/file.ts:45` — {why relevant}
```

**For subtasks**: The brief MUST reference the parent task's brief and inherit its context. Don't repeat everything — link to the parent and add what's specific to this subtask.

**Session ID capture**: Detect the runtime environment:

- OpenCode: `$OPENCODE_SESSION_ID` or parse from `~/.local/share/opencode/sessions/`
- Claude Code: `$CLAUDE_SESSION_ID` or the conversation ID from the CLI
- If unavailable: use `{app}:unknown-{ISO-date}` and note "session ID not captured"

### Step 6: Add to TODO.md

Format the TODO.md entry using the allocated ID:

```markdown
- [ ] {task_id} {title} #{tag} ~{estimate} ref:{task_ref} logged:{YYYY-MM-DD}
```

**Auto-dispatch eligibility**: Only add `#auto-dispatch` if the brief has:
- At least 2 acceptance criteria beyond "tests pass" and "lint clean"
- A non-empty "How (Approach)" section with file references
- A non-empty "What" section with clear deliverable

If the brief is too thin for auto-dispatch, omit the tag and note why.

### Step 7: Commit and Push

Commit both the brief and TODO.md change:

```bash
~/.aidevops/agents/scripts/planning-commit-helper.sh "plan: add {task_id} {short_title}"
```

The brief file (`todo/tasks/{task_id}-brief.md`) is a planning file and goes directly to main alongside TODO.md.

## Offline Handling

If `TASK_OFFLINE=true`, warn the user:

```text
[WARN] Allocated {task_id} in offline mode (+100 offset).
       Reconciliation required when back online.
       No GitHub/GitLab issue was created.
```

## Examples

```text
User: /new-task Add CSV export button
AI: Allocated: t325 (ref:GH#1260)
    Task: "Add CSV export button"

    Creating brief from conversation context...

    Brief: todo/tasks/t325-brief.md
    - What: Add a CSV export button to the data table component that exports
      the current filtered view as a downloadable CSV file
    - Why: Users need to export filtered data for offline analysis and reporting
    - How: Add ExportButton to DataTable toolbar, use papaparse for CSV generation
    - Acceptance: Button visible in toolbar, exports current filter, handles 10k+ rows

    1. Confirm and add to TODO.md
    2. Edit brief first
    3. Cancel
User: 1
AI: Added:
    - todo/tasks/t325-brief.md (brief)
    - TODO.md: - [ ] t325 Add CSV export button #feature #auto-dispatch ~1h ref:GH#1260 logged:2026-02-12
```

```text
User: /new-task Fix login timeout on mobile
AI: Allocated: t326 (ref:GH#1261)
    Task: "Fix login timeout on mobile"

    I need more context for the brief:
    1. What's the current timeout behaviour? (error message, redirect, etc.)
    2. Which auth provider? (Better Auth, NextAuth, custom)
    3. Mobile-specific or all platforms?

User: Better Auth, only on iOS Safari, users get logged out after 5 minutes
AI: Brief: todo/tasks/t326-brief.md
    - What: Fix premature session expiry on iOS Safari — sessions should last 24h
    - Why: iOS Safari users lose work after 5 min due to aggressive cookie handling
    - How: Check Better Auth session config, likely needs SameSite=None + Secure
      for iOS Safari cookie persistence. File: packages/auth/src/config.ts
    - Acceptance: iOS Safari session persists 24h, no regression on other browsers

    1. Confirm  2. Edit  3. Cancel
```

## CRITICAL: Supervisor Subtask Creation

When the AI supervisor creates subtasks (e.g., decomposing t005 into t005.1-t005.5), it MUST:

1. Create a brief for EACH subtask at `todo/tasks/{subtask_id}-brief.md`
2. Reference the parent task's brief: `**Parent task:** {parent_id} — see [todo/tasks/{parent_id}-brief.md]`
3. Inherit context from the parent but add subtask-specific details
4. Include the session ID of the supervisor session that created the subtask

A subtask without a brief is a knowledge loss. The parent task's rich context (from the original conversation) must flow down to every subtask.
